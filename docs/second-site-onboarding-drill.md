# 第二站接入演练（2026-10-31）

> **一句话**：从空库到「客户端能列出本站作品」，全程 **20 秒**（库 9s + 迁移与启动 10s + 建站 78ms + 导入 154ms），
> 只用了两个接口。演练抓到一个会漏内容的缺陷：**导入不校验来源属于哪个站**——已修。

## 1. 为什么练这个

对外的承诺是「接单后 3 天部署新站」，拆分见 `deployment-requirement.md` §3.3。
但 Day 1 的技术部分（起实例 → 迁移 → 建站 → 导入 → 行数核对）**从来没在「第二个站」上走过一遍**：
生产只有一个 otaku，而且它是从零长出来的，不是按清单接进来的。
「一套底座服务多站」这件事，只用 VNDB 在数据层证实过（`ROADMAP` §8.7），部署层没验。

## 2. 怎么做的（可复现，不碰生产）

```bash
# ① 第二站的库（模拟「另一台机器」：独立库、独立端口）
docker run -d --name otaku-site2-mysql -e MYSQL_ROOT_PASSWORD=site2 -e MYSQL_DATABASE=otaku \
  -p 127.0.0.1:3309:3306 mysql:8.0 --character-set-server=utf8mb4 --collation-server=utf8mb4_0900_ai_ci

# ② 同一个 jar，只改环境变量（这就是「接站不改代码」的全部内容）
DB_PORT=3309 DB_PASSWORD=site2 SERVER_PORT=8083 OTAKU_PUBLIC_BASE_URL=http://127.0.0.1:8083 \
  java -jar backend-java-0.1.0-SNAPSHOT.jar      # 启动即 Flyway 迁移 V1–V27

# ③ 建站（一个接口同时写 site 与 site_source 映射）
POST /internal/sites
{"site_key":"drill2","display_name":"演练二站","sources":["vndb"]}

# ④ 导入本站数据
POST /internal/import/batches
{"batch_id":"drill2-vndb-1","source":"vndb","items":[ …5 条… ]}
```

## 3. 结果

| 步骤 | 实测 |
|---|---|
| 库就绪（容器 + `mysqladmin ping`） | **9 s** |
| 应用启动（含 27 条迁移，空库） | **10 s** |
| `POST /internal/sites`（site + source 映射） | **78 ms**，201 |
| 导入 5 条作品 | **154 ms**，`inserted=5 rejected=0` |
| `GET /api/works` | `total=5`，5 条全在 |
| `GET /api/works/{id}` | 200，标题/标签正确 |
| `GET /api/tags` | `total=1`（`视觉小说`） |
| `GET /api/site/features` | `{"ugc_enabled":false,"ugc_moderation":"post"}`——新站社区默认关，符合产品口径 |
| 建第二个站抢同一个 `source` | **400**「建站冲突：…或有来源已被其它站点占用」 |

**Day 1 的技术部分（除域名/证书）落地时间 ≈ 20 秒**，剩下的是人按清单核对行数、配 `.env`（CORS/限流/封面白名单）。
「3 天」的预算主要花在**域名备案、证书、客户端烘焙、真机验收**——不是花在起服务上。

## 4. 抓到的缺陷：导入不校验来源归属

演练里往只登记了 `vndb` 的新站导了 2 条 `bangumi`：

```
POST /internal/import/batches  source=bangumi  →  200  inserted=2
GET  /api/works                →  total 从 5 变成 7
```

那两条作品的 `source` 不属于任何站点（`site_source` 没有映射），后果是：

- **客户端列得出来**——`/api/works` 不按站点过滤（单库单站模型下默认「库里的都属于本站」）；
- **评论挂不上**——`siteKeyOfSource` 为空 → `WORK_NOT_FOUND「作品不属于任何站点」`；
- 接第二个站时如果误把别站的批次导进来，**用户会看到另一个站的内容**。这正是「接站」最容易犯的错。

### 修复

`ImportService` 在入口校验：来源必须在 `site_source` 里登记过；**空库例外**（还没建站时允许先灌数据）。
一旦库里有站点，未登记来源直接 `400`，文案说清「客户端列得出来、评论挂不上」。

```
POST /internal/import/batches  source=bangumi  →  400
"来源 bangumi 未登记到任何站点：先用 POST /internal/sites 建站并指定 sources，否则这批作品客户端列得出来、评论挂不上"
```

单测 `ImportSourceRegistryTest` 三条：已登记放行 / 空库放行 / 有站未登记拒。

有个**紧急开关** `app.import.require-registered-source`（默认 `true`）。集成测试里关掉——
所有用例共用一个库，别的测试类建的站点会残留，开着会因为「有站但来源没登记」误红；
规则本身由单测与这次演练覆盖。线上不要关，除非要临时抢灌数据。

## 5. 演练确认的两条边界

1. **一个 `source` 只能属于一个站**（唯一键兜底，不是先查后插）：想「两个站共用一份数据」会被 400 挡住，
   要共用得复制数据或另建 source。这是隔离的底线，别绕。
2. **列表不按站点过滤**。单库单站模型下没问题；但这也意味着**「一个库放两个站」不成立**——
   `singleActiveSite()` 在多个 active 站点时返回空，`/api/site/features` 会 fail-closed（社区被当成关闭）。
   要服务第二个站，就再起一套库，别省这个库。

## 6. 没验的部分（依赖外部）

- 域名解析 + HTTPS 证书（#195）——`nginx/` 与 `init-letsencrypt.sh` 已备好，没域名跑不了；
- 客户端按站烘焙（品牌/包名/`base_url`）与真机验收——属 riceyu02 的链路；
- 真实来源站适配器（VNDB 之外）——`sync-python` 侧的事。

## 7. 这次演练改了什么

| 文件 | 改动 |
|---|---|
| `ImportService` | 入口新增 `requireSourceRegistered`（空库放行） |
| `WorkRepository` | 新增 `hasAnySite()`，区分「空库 bootstrap」与「已接站」 |
| 配置 | 新增 `app.import.require-registered-source`（默认 true；集成测试关） |
| 测试 | `ImportSourceRegistryTest` 3 条 |
| 本文 | 实测时间与两条边界 |
