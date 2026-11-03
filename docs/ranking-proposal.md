# W2 · 榜单能力方案

> 起草：@pyxz0 ｜ 2026-10-22 ｜ 更新：2026-10-24
> 上位：[`project-charter.md`](project-charter.md) §2.1 W2 · 归口 Issue #96
> **状态：B 档已实现（分支 `feat/min-rating-ranking`）。参数属契约变更（章程 §3.2 第 1 条），
> 合并前需三人确认。**

## 1. 结论先行

**「榜单」不需要新端点**——现有 `GET /api/works` 的 `sort` + `type` + `tag` 已经覆盖
评分榜（`sort=rating`）、年份榜（`sort=year`）、类型榜（`type=`）、标签榜（`tag=`）四种形态。

真正缺的只有两处**语义差异**：

| # | 差异 | 现有能力 | 结论 |
|---|---|---|---|
| D1 | 榜单**固定条数**（如 Top 100），不无限翻页 | `page_size` 上限 50，可翻页 | **不改**：客户端取前 N 页即可 |
| D2 | **无评分作品不参与**评分榜 | `sort=rating` 把 NULL 沉底，但仍在结果里 | **已实现**：新增 `min_rating` 过滤 |

于是分两档：**A 档（零改动，客户端拼参数）** 与 **B 档（加一个过滤参数）**。
A 档现在就能用，B 档补上「没评分不该上榜」这一条。

## 2. A 档：用现有参数拼榜单（零后端改动）

| 榜单 | 请求 | 说明 |
|---|---|---|
| 全站评分榜 | `GET /api/works?sort=rating&page_size=50` | 取前 1–2 页即 Top 50–100 |
| 某类型评分榜 | `GET /api/works?type=anime&sort=rating` | 类型榜 |
| 某标签评分榜 | `GET /api/works?tag=科幻&sort=rating` | 标签榜 |
| 年份新作榜 | `GET /api/works?sort=year` | 年份榜 |

**优点**：不新增契约、不新增端点、客户端今天就能做。
**缺点**：无评分作品会沉底但**仍占名次**，翻到末页会看到一堆无评分作品。

## 3. B 档：`min_rating` 过滤参数（已实现）

为「评分榜」补一条语义：**只让有评分的作品参与排名**。

```
GET /api/works?sort=rating&min_rating=7.0   # 只返回评分 ≥ 7.0 的作品，按评分降序
```

- 语义：过滤「评分低于该值」的作品，`NULL`（无评分）**一律排除**——`NULL >= 7` 不成立，
  所以不需要额外写 `IS NOT NULL`。
- `min_rating=0` 有独立含义：**只要有过评分**。这与不传参数不同，前者排除无评分，后者全都要。
- 与 `sort` / `type` / `tag` / `q` 任意组合；缺省 = 不过滤。
- 取值 `[0, 10]`：库里 `rating_scale` 当前全是 `0-10`（otaku_site 与 bangumi 皆是）。
  非数字 / 负数 / 超上限 → `400`，与「筛出来是空」区分开，避免客户端把参数写错当成「榜单是空的」。
- 实现：`WHERE rating_value >= :min`，**零新索引、零迁移**。

### 3.1 两条查询路径（性能上的关键）

列表按有没有 `tag` 走两条 SQL，`min_rating` 必须两条都覆盖，且用对列：

| 路径 | 条件落在 | 用到的索引 |
|---|---|---|
| 无 `tag` | `work.rating_value >= ?` | `idx_work_rating (rating_value, id)`（`V6`） |
| 有 `tag`、无 `q` | `work_tag.rating_value >= ?`（V7 冗余列，**不回表**） | `idx_work_tag_rating (tag, rating_value, work_ref)` |
| 有 `tag` + `q` | 回表到 `work.rating_value`（本来就要 JOIN work 查标题） | `idx_work_tag_type` + 回表过滤 |

有 `tag` 时若图省事写成 `w.rating_value`，就会白白多一次回表：V7 建表时特意把
`rating_value` 冗余进 `work_tag` 就是为了「标签 + 评分」不用回表（见 `V7__work_tag_filter.sql` 注释）。

## 4. 明确不做（避免过度设计）

- **不新增 `/api/rankings` 独立端点**——现有 `sort` 就是榜单，另起端点只会让客户端二选一、契约重复。
- **不做「热门榜」（按收藏数）**——收藏数是账号侧数据，跨模块聚合要冗余计数列，且当前用户量不足以支撑可信热度。
- **不做「评分人数加权」**——只有来源站单一评分值，没有「评分人数」这个维度，无米之炊。
- **不做涨跌榜 / 时间窗榜**——库里没有历史评分快照，无法计算「近 7 日上升」。要做先得有采集侧的时间序数据。

## 5. 验证

```
cd backend-java
./mvnw -B test                    # 116 项，0 失败（9 项集成测试按设计跳过）
IT_DB_PORT=3307 ./mvnw -B test    # 116 项，0 skipped（真实 MySQL 8.0）
```

- 单元测试（`WorkServiceSortAndRelatedTest`）：解析、透传、空值、边界 `0`/`10`、
  四种非法值 400 且不碰数据库、计数与取页两处条件一致。
- 集成测试（`WorkTagFilterIntegrationTest#minRatingExcludesUnrated`）：真实 MySQL 上
  **两条查询路径**都要生效——全站路径用「有评分条数」核对总数（不假设库里只有测试数据），
  标签路径核对具体命中与无评分排除。

## 6. 需要三人确认的点

1. **参数名与语义**：`min_rating` + 「NULL 一律排除」+ 「0 = 只要有过评分」，是否认可？
2. **尺度假设**：当前按来源评分尺度 0–10 校验。将来接非 0–10 尺度的站点时，
   是扩展这个参数（如同时传 `rating_scale`），还是要求导入侧统一归一到 0–10？
   **这条会决定要不要现在就把 `rating_scale` 拉进过滤条件。**
3. **是否要「固定 Top N」**：如果客户端只取前 2 页，D1 可以永久不做。

## 7. 未做 / 未测（如实记）

- **没在 55.6 万条上实测**：本机当前库只有 107 条，性能结论只能等有全量数据的机器补测。
  第 3.1 节的索引判断来自索引结构与 `V6`/`V7` 建表时的实测记录（那张表上的既有结论），
  **不是本次新测的耗时**——不要对外引用成「榜单查询 X ms」。
- **客户端未接入**：本 PR 只有后端与契约；榜单页在 W1 客户端侧，需另行排期。
- **`tag` + `q` + `min_rating` 三个条件同时上**未单独测；`tag+q` 本身已有约 720ms 的
  已知成本（LIKE 求交集的固有开销），加一个范围条件不会改变量级，但会略微增加过滤成本。

## 8. 低票不进排序（#383）：别直接把 `ORDER BY` 改成 `CASE`

首站口径（`app/rating.py`，`MIN_RATING_COUNT = 50`）三档，**展示与排序是两个函数**：

| `rating_count` | 展示 | 排序 |
|---|---|---|
| `NULL` | 照常（不动存量） | 用 `rating_value` |
| `< 50` | `--` | 按 **0** 算 |
| `>= 50` | 照常 | 用 `rating_value` |

### 8.1 现在的数据状态（2026-11-03 生产实测）

- `work.rating_count` 列**已在生产**（11-02 急救期手工加的），补迁移在 PR #386 的 `V29__work_rating_count.sql`（幂等写法，列已存在则跳过）；
- 但**回填一行都还没落库**：`site_listed=1` 的 18,828 条里 `rating_count` 非空 **0 条**。
  也就是说现在把「按阈值展示」上线，页面上**什么都不会变**——`NULL` 按可信处理，17,856 条评分照旧显示。

### 8.2 为什么排序不能直接改 ORDER BY（本轮实测）

`WorkSort.RATING` 现在是 `rating_value DESC, id DESC`，靠 `idx_work_rating` 反向索引扫描取前 20 行。

| 写法 | EXPLAIN | 首屏 |
|---|---|---|
| `ORDER BY rating_value DESC, id DESC` | `idx_work_rating`，**Backward index scan**，rows=**20** | API 实测 **9–14 ms**（第 100 页 38–40 ms） |
| `ORDER BY (CASE WHEN rating_count < 50 THEN 0 ELSE rating_value END) DESC, id DESC` | `type=ALL`，扫 **163,229 行**，`Using filesort` | 单条 SQL **133 ms**（含客户端开销，实际约 90–100 ms） |

同一个道理在标签路径上已经吃过一次：V7 建表时记录过「有序扫描 35 ms vs filesort 772 ms」。
**排序键一旦变成表达式，索引就用不上了**，这是代价的来源，不是写法问题。

### 8.3 做法（已实现，见 `V30__work_rating_sort.sql`）

1. **加一个 VIRTUAL 生成列** `rating_sort`：
   `CASE WHEN rating_count IS NOT NULL AND rating_count < 50 THEN 0 ELSE COALESCE(rating_value, 0) END`，
   配 `(rating_sort, id)` 索引。选 VIRTUAL 而不是 STORED：虚拟列不重写表（只建索引），
   索引仍把算好的值存下来，排序按索引取值、不逐行计算；写入零改动，回填 `rating_count` 时自动重算。
2. **展示层在 Java 映射时置空**（`rating_count < 50` → `main_rating = null`），SQL 不动；
   客户端拿到的就是 `null`，渲染 `--`，不需要新字段。`rating_count` 为 `null` 时**不隐藏**
   （按「可信」处理，否则回填跑到一半会半屏没分）。
3. `work_tag` 的冗余 `rating_value` 这轮不动：标签内排序要同样口径得再加冗余列，
   属于第二批（现在标签内也没有「按评分排」的入口）。**已知差异**：带 `tag` 时低票作品仍按原分排。
4. `min_rating` 语义**保持不变**（`0` = 只要有过评分）。改成「低票也算无评分」会让现有榜单口径
   静默变化，要改另开一条。
5. 阈值在两处（Java 常量 `WorkService.MIN_RATING_COUNT`、V30 里的字面量），
   由 `RatingThresholdConsistencyTest` 读迁移文件比对，改漏一处会红。

### 8.4 实测（2026-11-03，生产数据副本）

生产 61MB dump → 本地 MySQL 8.0 副本（209,428 行 `work`）→ 让 Flyway 自己跑 V29 + V30：

| 项 | 结果 |
|---|---|
| `V29`（`rating_count`，生产已有列 → 幂等跳过） | **14 ms** |
| `V30`（虚拟生成列 + 索引，209,428 行） | **911 ms** |
| 迁移后 `EXPLAIN`（`ORDER BY rating_sort DESC, id DESC`） | `idx_work_rating_sort`，**Backward index scan**，rows=**20** |
| 真实数据验证 | 把一棵 9.4 分的头部作品 `rating_count` 改成 10 → 列表里不再排第一、`main_rating` 变 `null`；详情同样为 `null`；其余作品评分不受影响 |
| 回归测试 | **401 通过 / 0 skipped**（新增 `RatingThresholdIntegrationTest` 2 项、`RatingThresholdConsistencyTest` 1 项） |

反证也做了：把 `WorkSort.RATING` 改回 `rating_value DESC`，集成测试立刻红
（`expected "it-rating-ok" but was "it-rating-low"`），说明这个测试真的打在排序上。

### 8.5 一个硬顺序约束（已解除）

`V29` 当时在 #386 里，**没合之前不能加 `V30`**：Flyway 按版本号顺序应用，先应用了 V30 再收到 V29，
会被判成乱序迁移直接启动失败。#386 于 11-02 合入后此约束解除，本 PR 才带上 V30。
