# 接口性能基线

> 用途：改查询 / 加索引 / 换缓存前后，拿同一组请求对比。没有基线就只能凭感觉说「好像快了」。
>
> 采集环境：生产机（腾讯云 Lighthouse 2C2G），**在服务器上 curl 127.0.0.1**，排除公网与客户端变量。
> 时间：2026-11-06 22:15，版本 `b33`（`98a03fec`）。
> 数据量：`work 209,428`（可见 18,676）、`work_tag 527,775`、`work_staff 183,388`、
> `work_characters 75,745`、`people 19,399`、`article 689`。

## 1. 公开读

| 请求 | 耗时 | 备注 |
| --- | --- | --- |
| `/api/works?page=1&page_size=20` | 8 ms | 首屏 |
| `/api/works?page=100` | 9 ms | |
| `/api/works?page=500` | 39 ms | |
| `/api/works?page=900` | **136 ms** | 接近尾页（共 934 页），O(OFFSET) |
| `/api/works?tag=机战&page=1` | 5 ms | 走 `work_tag` 索引 |
| `/api/works?tag=机战&page=50` | 5 ms | 深页也不退化 |
| `/api/works?sort=rating` | 6 ms | 走 `rating_sort` 生成列 |
| `/api/works/{id}` | 5 ms | staff 30 / chars 60 |
| `/api/works/{id}/related` | 27 ms | 实时算，无预计算表 |
| `/api/persons/{id}` | **140–170 ms** | 见 §3，缺 `person_id` 索引 |
| `/api/tags` | 9 ms | |
| `/api/schedule` | 28 ms | |
| `/api/schedule/seasons` | 3 ms | |
| `/api/articles?page=30` | 24 ms | |
| `/api/articles?category=动画` | 7 ms | |
| `/api/articles/{id}/related` | 11–65 ms | 首次含冷启动 |
| `/api/site/features` | 4 ms | |
| `/api/app/config` | 2 ms | |
| `/api/covers/{id}` | 见冒烟 | 命中缓存时 200；白名单失效会 404（#188 的护栏） |

## 2. 已知的两个慢点

### 2.1 深页 O(OFFSET)——暂不修

`page=900` 是 136 ms，与 offset 近似线性；`page ≤ 100` 都在 10 ms 内。
**触发阈值**（与 #384 一致）：`page >= 200` 的 P95 > 200 ms，或作品量翻倍到 ~4 万。

键集分页要改契约（客户端带游标），不是后端单方面能定的。

### 2.2 人物页索引（V36 已补，2026-11-07）

`/api/persons/{id}` 的 140–170 ms 原先全花在「按 `person_id` 扫两张关系表」上
（`work_staff` + `work_characters` 只有 `work_ref` 前缀索引）。#476 把三条扫描合成一条，
从 **0.46–0.57 s** 压到 140–170 ms；**b35 的 V36** 补了
`idx_work_staff_person` / `idx_work_characters_person`，热身后实测 **46–66 ms**。

V33（#362 人物前缀）落地后迁移号不再被挡，所以索引与 people 键补齐放在同一个 V36。
详见 `PersonRepository` 类注释。

## 3. 怎么复现

```bash
B=http://127.0.0.1:8080
t() { curl -s -o /dev/null -w "%{time_total}" "$1"; }
t "$B/api/works?page=1&page_size=20"   # 先打一次暖缓存，不计
for u in "/api/works?page=1&page_size=20" "/api/works?page=900&page_size=20" \
         "/api/persons/bgm%3A3818"; do
  printf "%-46s %s\n" "$u" "$(t "$B$u")"
done
```

注意：

- **必须同机 curl**。从开发机测会把公网 RTT 算进去（国内通常 +20–40 ms），掩盖真实差异；
- 每项先打一次再计，避免 JIT / 连接池 / 页缓存的冷启动混进来；
- 改完查询后对比同一组 URL，不要只测改动的那个。

## 4. 历史

| 日期 | 版本 | 变化 |
| --- | --- | --- |
| 2026-11-07 | `b35` | V36 补 `person_id` 索引；人物页热身后 **46–66 ms**（140–170 → 46–66） |
| 2026-11-06 | `b33` | 建立基线；人物页从 0.46–0.57 s 降到 140–170 ms（#476） |
