# 备份恢复演练（2026-10-31）

> **一句话**：57.4 MB 的生产 dump 在干净实例上 **27 秒**导完，**24/24 张表行数一致**、
> **9 张关键表 `CHECKSUM TABLE` 一致**、**Flyway 27 条迁移历史逐条一致**；
> 后端直接对着恢复出来的库启动，列表 / 详情 / 评论 / 标签 / 年份筛选的响应与生产**逐字节相同**。

## 1. 为什么要单独做这一遍

CI 的 `deploy-lint` 里其实每次都在跑「dump → 恢复到独立库 → 比对行数」，但那是**合成出来的 2 行数据**。
它证明得了「脚本能跑」，证明不了「真实数据能回来」。真实 dump 有 19 万部作品、45 万条关系行，
能把三类问题暴露出来：

| 风险 | 真数据才会暴露 |
|---|---|
| 导出被截断 | 大表 `--quick` 没生效、连接中断写出半个文件 |
| 字符集/排序规则 | 中文标题、`utf8mb4_0900_ai_ci` 不一致会在导入时报 1273 / 1267 |
| 迁移历史对不上 | Flyway 校验失败 → **应用起不来**，而这在「只查备份新鲜度」的巡检里完全看不见 |

**备份没恢复过 = 没有备份。** 巡检第 4 项只看「备份文件是否 < 26 小时」，看不出可用性。

## 2. 这次怎么做的（可复现）

恢复**不在生产机上做**——2G 内存的机器同时跑 MySQL 和生产后端，再起一个实例去导入 400 MB 数据，
OOM 的概率比演练的价值大。全程在本地做，生产只出 dump。

```bash
# ① 生产：用 backup.sh 同一套参数导出（--single-transaction，9 秒，不锁表）
ssh pyxz0@<host> 'cd /opt/otaku/backend && docker compose -f compose.prod.yaml exec -T mysql \
  sh -c "exec mysqldump -uroot -p\"\$MYSQL_ROOT_PASSWORD\" --single-transaction --quick \
         --set-gtid-purged=OFF --default-character-set=utf8mb4 otaku" | gzip > /tmp/drill.sql.gz'
# ② 本地：拉到演练目录（57 MB；这条链路只有 ~480 KB/s，2 分钟）
scp pyxz0@<host>:/tmp/drill.sql.gz .

# ③ 本地起一个干净的 8.0，字符集/排序规则与生产一致
docker run -d --name otaku-drill-mysql -e MYSQL_ROOT_PASSWORD=drill -e MYSQL_DATABASE=otaku \
  -p 127.0.0.1:3308:3306 mysql:8.0 \
  --character-set-server=utf8mb4 --collation-server=utf8mb4_0900_ai_ci

# ④ 导入（27 秒，stderr 必须为空）
gunzip -c drill.sql.gz | docker exec -i otaku-drill-mysql mysql -uroot -pdrill \
  --default-character-set=utf8mb4 otaku

# ⑤ 对照：逐表行数 + 关键表校验和 + 迁移历史
#    两边跑同一份 counts.sql（24 张表 union all），diff 必须为空
diff <(prod_counts) <(drill_counts)
```

第 ⑤ 步之后再加一步「能不能用」：把本地打好的 jar 指向 3308 起一个实例，
`/actuator/health` 起来后与线上逐个接口比对。

## 3. 结果

| 项 | 生产 | 恢复实例 | 结论 |
|---|---|---|---|
| dump 大小 / 耗时 | 57,439,731 B / **9.2 s** | — | 导出不锁表，`gzip -t` 通过 |
| 导入耗时 / 报错 | — | **27 s** / **0 行 stderr** | 干净导入 |
| 24 张表行数 | 24 行 | 24 行 | `diff` 为空 |
| `CHECKSUM TABLE`（work / work_tag / people / work_staff / work_characters / work_studios / app_user / ugc_comment / ugc_review） | 9 个校验和 | 完全相同 | 内容级一致，不只是行数 |
| Flyway 历史 | 27 条，末条 `V27` | 完全相同 | 恢复后能直接启动，不会被校验拦住 |
| `/api/works` total | **190,650** | **190,650** | 一致 |
| 首两条作品 | `W-e70201dhttf5ayr` / `W-j6xt69esy62msfg` | 相同 | 一致 |
| 详情 / 评论列表 / 标签 / 年份筛选 | — | — | 除 `OTAKU_PUBLIC_BASE_URL`（封面地址前缀）外**逐字节相同** |
| 停掉演练库之后 | — | `/actuator/health` → **503** | 证明它确实连的是恢复库，没有连到别处 |

RTO 粗估：导出 9 s + 传输 2 min（受带宽限制）+ 导入 27 s + 启动 7 s ≈ **3 分钟**，
其中**传输是大头**——异地恢复会更慢，这条比任何代码优化都值得记住。

## 4. 结论与后续

- 备份链路**可用**：dump → 传输 → 导入 → 启动 → 对外服务，整条走通了。
- 恢复实例的响应与生产一致，说明「恢复后要不要重建缓存/重算」这类担心在这套系统里不存在
  （没有外部缓存，封面是文件缓存，丢了会回源）。
- **演练完当场删掉本地 dump**——那是全量生产数据，不该长期躺在个人电脑上。
- 建议：**每季度一次**；每次大改 schema（新迁移）之后加一次，重点看 Flyway 校验能不能过。
- 已知限制：
  - 逻辑备份只能恢复到 **同大版本**（8.0）；换 8.4 要先单独验一次。
  - 单机备份，**没有异地副本**——整机挂了备份跟着没（`deploy-production.md` §0 第 9 条一直没落实）。
  - dump 里的 `ugc_*` 表在演练时是空表（线上还没有真实评论），UGC 有量之后要再跑一次。
