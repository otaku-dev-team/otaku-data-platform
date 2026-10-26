# 列表分页性能实测：真正的成本是 `COUNT(*)`，不是深页

> 日期：2026-10-26 ｜ 执行：@pyxz0 ｜ 数据：55.6 万条合成数据（本机 MySQL 8.0.46，临时实例）
> **一句话**：文档一直在讨论「深页 OFFSET 慢」，实测下来**每一页都在付的 `COUNT(*)`（76–126 ms）才是主要成本**；
> 键集只能把深页那部分省掉，省不掉 `COUNT`。

---

## 1. 为什么要测

`ROADMAP` 与 `stage3-reliability-record` 里长期挂着两条：

- 深页 `LIMIT/OFFSET` 是 O(OFFSET)，要改键集（**属契约变更**，一直没动）；
- 第 11000 页 ~490 ms。

改键集要动契约（新增 `cursor`），所以先得回答一个问题：**改了到底能省多少、值不值得动契约。**
这份就是那个实测。

---

## 2. 方法

- 临时 mysqld 实例（3307），库 `perf`，表结构**照 Flyway 迁移逐字复制**（V1 的 `work` + V5 的 `release_year` + V6 的 `idx_work_rating` / `idx_work_year`）；
- 灌入 **556,342** 条合成数据，**分布对齐真实数据**：无评分占 64%（实测真实值 63.8%）、四种 `work_type` 均匀；
- 用 `SET profiling=1` 取服务端耗时，**先跑一遍预热**再取数，排除冷缓存；
- 查询语句照 `WorkRepository` 的实际 SQL 写（两段式：内层取 id、外层回表）。

---

## 3. 实测结果

### 3.1 现状：两段式 + OFFSET

| 操作 | 耗时 |
|---|---|
| `COUNT(*)`（无筛选） | **126 ms** |
| `COUNT(*)` + `work_type='anime'` | **76 ms** |
| 取第 1 页 id（OFFSET 0） | 0.4 ms |
| 取第 1000 页 id（OFFSET 49,950） | 33 ms |
| 取第 5000 页 id（OFFSET 249,950） | 158 ms |
| 取第 11000 页 id（OFFSET 549,950） | 195 ms |
| **第 11000 页端到端**（内层 + 回表，取 3 列） | **176 ms** |
| `type=anime` 深页（OFFSET 139,000） | 60 ms |

### 3.2 键集（cursor）等价写法

| 操作 | 耗时 | 相对现状 |
|---|---|---|
| `WHERE id > 550000 ORDER BY id LIMIT 50`（回表） | **0.49 ms** | 深页 176 ms → 0.49 ms（**360×**） |
| `WHERE (rating, id) < (…)` 评分排序深页 | **0.84 ms** | 88 ms → 0.84 ms（**105×**） |
| `type=anime AND id > 550000` | 0.69 ms | 60 ms → 0.69 ms |

### 3.3 关键：拆开看总成本

| 场景 | COUNT | 取页 | 合计 |
|---|---|---|---|
| 现状 第 1 页 | 126 ms | 0.4 ms | **≈126 ms** |
| 现状 第 11000 页 | 126 ms | 176 ms | **≈302 ms** |
| 键集 第 1 页 | 126 ms | 0.5 ms | **≈126 ms** |
| 键集 第 11000 页 | 126 ms | 0.5 ms | **≈126 ms** |
| 键集 + 不算 total | 0 | 0.5 ms | **≈0.5 ms** |

**这就是结论**：只改键集，深页从 ~302 ms 降到 ~126 ms（省 58%），但**下限被 `COUNT(*)` 钉死**；
要进到毫秒级，必须同时放弃精确 `total`。

---

## 4. 这说明什么

1. **优化重点可能搞反了。** 文档一直在讨论深页，但深页只有翻得极深才付；`COUNT(*)` 是**每一页都付**。
   一个只翻 3 页的用户，今天也要付 3 次 126 ms。
2. **改键集的收益上限是 58%，且只对深页生效。** 要拿到数量级提升，绕不开 `total`。
3. **`total` 是契约里的硬要求**（`Paging.total`：「客户端靠它判断是否末页，必须返回」）。
   所以真正的问题不是「要不要改键集」，而是「**客户端到底需不需要精确 total**」。

### 三个方案（按性价比）

| 方案 | 改动 | 效果 | 契约影响 |
|---|---|---|---|
| **A. 缓存 COUNT** | 按查询指纹缓存 total，短 TTL（如 30–60 s） | 首屏 126 ms → 首次 126 ms、后续 ~0 | 无 |
| **B. A + 键集** | 再加 `cursor` 参数 | 深页 302 → ~5 ms | 新增可选参数（向后兼容） |
| **C. 放弃精确 total** | 用 `has_more` + `next_cursor` 替代 `total`/`total_pages` | 全页 ~1 ms | **破坏性**：客户端与契约都要改 |

**建议先做 A**：不改契约、改动小、命中「每页都在付」的真问题。
B 可以随后做（收益只在深页）。C 只有在产品确认「不需要总数」时才值得——但那时收益是数量级的。

---

## 5. 未验证 / 局限

1. **合成数据的 `summary` 为 NULL**。真实行有最长 7225 字的简介，页密度更低、回表更贵——所以本文的取页耗时是**下限**，真实可能更差。
2. **本机单实例、SSD、warm cache**。生产（共享盘 / 云数据库 / 冷缓存）会更慢，比例关系大致成立，绝对值不可直接外推。
3. **没测 `q`（LIKE）与 `tag`（JOIN work_tag）组合**——那两个各自有独立的成本，不在这份范围内。
4. **没测真实翻页深度**。深页优化值不值得做，取决于用户实际翻到第几页；
   建议在客户端或后端加一个 `page` 分布埋点，用真实数据决定 B 的优先级。
5. **`COUNT(*)` 的 126 ms 是 InnoDB 全索引扫描**，换成 `information_schema` 估算或缓存都是权衡，本文只测了现状。

---

## 6. 复现

```bash
# 临时实例 + 建表（结构照 Flyway V1/V5/V6）
mysqld --defaults-file=… --initialize-insecure
mysqld --defaults-file=… --init-file=… &   # 建 otaku@%

# 灌 556,342 条（10^6 组合过滤）
INSERT INTO work (...) SELECT ... FROM
  (SELECT a.n+10*b.n+100*c.n+1000*d.n+10000*e.n+100000*f.n AS n
   FROM seq a, seq b, seq c, seq d, seq e, seq f) t WHERE t.n < 556342;

# 取耗时
SET profiling = 1;
SELECT COUNT(*) FROM work;
SELECT w.id FROM work w WHERE 1=1 ORDER BY w.id ASC LIMIT 50 OFFSET 549950;
SELECT w.id FROM work w WHERE w.id > 550000 ORDER BY w.id ASC LIMIT 50;
SHOW PROFILES;
```
