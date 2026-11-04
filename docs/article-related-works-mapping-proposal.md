# #408 资讯→作品：content_id → subject_id 映射方案（草稿 · 需三人确认）

> 状态：**草稿，供三人确认**。涉及新增数据结构与跨模块数据契约，按 `AGENTS.md` §3.2 / 章程 §3.2
> 需三人确认、走 PR，**本文件不代签**。
> 关联：issue #408、epic #403、`docs/relation-algorithm.md` §1 / §5.2 / §9.1、
> `V9__article.sql`、`V28__site_listed.sql`、`docs/旧站能力复用清单`、`docs/site-listed-migration.md`。
> 日期：2026-11-04。

## 0. 结论先行

**#408 不是「零后端改动的前端快赢」。`relation-algorithm.md` §1 那句「数据链路已通，仅差前端渲染」是误判。**

链路只通到「来源站 id 原文落库」，没通到「可渲染的作品对象」。按原目标（复用
`CompactWorkCard` 渲染本地作品卡）落地，必须先补一张 `content_id → bangumi subject_id`
映射表，并给资讯详情接口增加已解析的作品列表字段。这两件事都属于**数据结构 + 跨模块契约**，
因此 #408 会从 `relation-algorithm.md` §9.1 里「不受门禁、可立即推进」的快赢，
变成「需三人确认才能开工」的常规条目——这一点需要一并拍板，别默认沿用旧的定性。

## 1. 证据链（为什么不能直接渲染）

| 事实 | 证据 |
| --- | --- |
| `related_work_ids` 是来源站 **content_id**，不是平台 `work_id` | `sync-python/src/sync/article_html.py:36` 正则 `/contents/(\d+)`；样例 `7556` / `7613`（`sync-python/tests/conftest.py:533`） |
| 后端详情**原样透传**，不做任何解析 | `backend-java/.../article/ArticleService.java:109` `readStringList(record.relatedWorkIdsJson())`；DTO `ArticleDtos.ArticleDetail` 第 11 个字段 |
| 契约明文「不回填本地 work_id」 | `V9__article.sql:24-27`、`docs/openapi.yaml:4033` / `:4088`；`app-client/lib/data/models/article.dart:113-118` 注释同口径 |
| content_id 与 bangumi subject_id **是两套号** | `V28__site_listed.sql` 文件头：只按数值 join 会撞出 **3,015 条假匹配**；`docs/site-listed-migration.md` §2 复述 |
| 映射表**不在我们库里** | `site_scope(subject_id)` 只存 bangumi_id，V28 注释「为什么只存 subject_id、不存 content_id」；全库迁移只有 `V28` / `V8` 提到 `content_id` |
| 不能按 `(source='otaku_site', content_id)` 接 work | V28 把这 1.09 万行**真软删**并置 `site_listed=0`；详情接口对 `deleted_at IS NOT NULL` 与 `site_listed=0` 均返 404，接上去是死链 |
| 卡片需要的数据拿不到 | `CompactWorkCard` 入参是 `WorkSummary`（`work_id` / `title` / `coverUrl` / `mainRating`），`work_id` 是平台不透明字符串，不能用 content_id 顶替 |

结论：直接把 `related_work_ids` 塞进卡片，只会得到一串裸数字，或点了大批 404 / 串到错误作品。

## 2. 目标与边界

- **目标**：资讯详情页渲染横滑的**本地作品卡**，点击能进有效作品详情；复用 `CompactWorkCard`，
  客户端只渲染、不自算（#403 协作约定）。
- **非目标**：不改写 `related_work_ids` 字段语义（V9「存原文」的口径保留，供 §5.3 资讯反向查用）；
  不引模型、不做关联打分重排、不动 `design-style.md` §11 已冻结存量。
- **不采用的捷径**：按数值 join、`CAST(content_id AS UNSIGNED)` 当 subject_id、拿 content_id 当
  `work_id` 跳详情、把来源站 `/contents/{id}` 外链伪装成本地作品卡。

## 3. 映射数据从哪来（决策点 D2）

首站 `/api/contents` 列表与详情都返回 9 字段，**同时含 `id`（content_id）与 `bangumi_id`**
（`sync-python/src/sync/source.py` 模块 docstring；`docs/旧站能力复用清单` 第一节）。

| 方案 | 做法 | 代价 / 风险 |
| --- | --- | --- |
| **A（建议）分页拉 JSON API** | 按 `type` 逐类分页遍历 `/api/contents?page=N&page_size=200`，取 `(id, bangumi_id)` 落表 | 遵守站主限流：`page_size ≤ 200`、并发 ≤ 2、1–2 req/s、每日 ≤ 5 万请求；需失败页记账与可重跑；站点**无 SLA / 无版本承诺**（旧站清单明确） |
| B 数据集导出工具直连首站库 | 复用 `sync-python/src/sync/dataset/mappings/otaku-bangumi.json` 的连接方式，一条 SQL：`SELECT CAST(c.id AS CHAR), CAST(c.bangumi_id AS CHAR) FROM contents c` | 最快、无限流；但依赖首站 DB 连接与凭据，且要确认该通道在交付口径里可用 |
| C 从 `schedule.content_id` 反推 | 用档期链已回填的 `work_id` 建映射 | **覆盖不全**（只有档期作品），只能做校验不能做主来源 |

> ⚠️ 别引用 `docs/旧站能力复用清单` 那句「映射表彻底不需要了」——它只针对**封面路径**
> （`cover_url` 已直接返回），不适用于资讯关联场景。

规模口径：`site_scope` 白名单来自 `contents.bangumi_id` 共 18,828 条（2026-11-02 实测，
`open-decisions.md:181` 记 `contents` 表 18,828 部、`bangumi_id` 覆盖率 100%）。
**映射表实际行数、`related_work_ids` 的命中率都需在真实数据上重测**，本文不预填结论。

## 4. 落库设计（决策点 D1 / D6）

```sql
-- 号待定：见「迁移号协调」
CREATE TABLE work_content_map (
  content_id VARCHAR(128) NOT NULL COMMENT '首站 contents.id 原文（/contents/{id} 的 id）',
  subject_id VARCHAR(128) NOT NULL COMMENT '首站 contents.bangumi_id 原文，= work(source=bangumi).source_id',
  PRIMARY KEY (content_id),
  KEY idx_subject (subject_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='首站 content_id → bangumi subject_id 映射（#408）';
```

两个刻意的取舍：

- **`subject_id` 用 VARCHAR 存原文**，与 `work.source_id` 同类型。这样 JOIN 直接写
  `w.source_id = m.subject_id` 命中 `uk_work_source`，**不用 `CAST(... AS UNSIGNED)`**——
  V28 为了对上 `site_scope.subject_id` 的 BIGINT 才做 CAST，这里没必要重演。
- **不存 `work_id`**：只存来源侧两套号的对应，`work_id` 由查询时按
  `(source, source_id)` + 三条件实时解析。避免 `site_listed` / 软删变化后表里留死链。

回填策略：映射导入做成**幂等 upsert**（`content_id` 唯一键），可重复跑；不要挂在资讯导入事务里
逐条写。首站新增作品后的增量频率与触发方式 **D2 一并确认**（建议先手动重跑，不急着上 cron）。

**迁移号协调**：本地与远端迁移目前只到 `V30`；`V31` 已被 #362 前缀迁移 + 列宽 A 预定
（`relation-algorithm.md` §9.1 明确「勿撞 V31」），`V32` 留给 #401 浏览表。
本方案的表**必须等 #362 合并后按 `ls | sort -V` 取下一个可用号**，不要预占、不要改已应用的迁移。

## 5. 契约改动（决策点 D3 / D7）

只改 `docs/openapi.yaml` 一处，三端跟随；字段一律 snake_case。

```yaml
# ArticleDetail（openapi.yaml:4025，allOf ArticleSummary + 两个字段）
related_work_ids:            # 保留，兼容 + 供反向查
  type: array
  items: { type: string }
  description: 来源站「关联作品」的站点作品 id 原文，透传不回填
related_works:               # 新增
  type: array
  items: { $ref: "#/components/schemas/WorkSummary" }
  description: >-
    已解析且当前可展示的本地作品，顺序与 related_work_ids 一致；
    未命中映射、或不可展示（见 §6 三条件）的 id 不出现在数组里。
    空数组 = 无可展示作品，不是错误。
```

- **复用 `WorkSummary` schema**，不新建 DTO → `ContractDriftTest` 的 `ArticleDetail` 映射
  （`backend-java/src/test/java/com/otaku/common/ContractDriftTest.java:212`）要跟着核对字段；
  若最终决定新建响应 DTO，则**必须登记进该测试的两张表**（`AGENTS.md` 硬约束）。
- 改完跑 `python scripts/check-contract.py`；库结构变了要重生 `test/fixtures/real_*.json`。
- 兼容：老客户端忽略未知字段；旧缓存缺 `related_works` 解析为 `null` → 整块不渲染。

## 6. 后端查询口径（三条铁律）

`ArticleService.toDetail` 增加一次**批量**解析：

1. `related_work_ids` → `work_content_map` 取 `subject_id` 列表（一次 `IN`）；
2. `work` 查询必须同时带 **`source = 'bangumi'`**、**`site_listed = 1`**、**`deleted_at IS NULL`**；
   少一条就会给出 404 死链（V28 / 详情接口口径）。
3. 按来源站**原始顺序**重排结果，`IN` 查询返回无序，不能拿数据库顺序当展示顺序。

其余口径：

- **一次 `IN`，禁止 N+1**；`WorkRepository.deletedState`（`:507-514`）有现成的批量范式。
- **数量上限**：建议截断到前 N 条，N 值 **[待定，建议 20]**，避免单条资讯拖出几十次渲染。
- **失败降级**：映射表缺行 / 查询异常 → `related_works: []`，详情主流程照常 200。
  参照 `RelatedWorksSection` 的取舍：推荐区是锦上添花，不能把正文拖进错误态。
- **不缓存静态结果**：`site_listed` 与软删状态会变，过滤必须每次请求实时做。
- 复用现有 `WorkSummary` 组装逻辑，别在 article 包里另写一套字段映射。

## 7. 客户端改动（第三阶段）

- `ArticleDetail` model 新增 `relatedWorks: List<WorkSummary>`（复用 `WorkSummary.fromJson`）。
- `article_detail_page.dart` 在正文之后接横滑区，复用 `CompactWorkCard` + `heightFor()`，
  `heroTag` 用 `article-related-$index` 保证屏内唯一（#391 已验证标签唯一性是硬要求）。
- 语义与 `related_works_section.dart` 一致：`null` / 空数组 / 失败 → **整块不渲染**，
  不显示「暂无推荐」；加载中给等高占位避免抖动。
- 不动 `design-style.md` §11 冻结项，不碰色板与令牌。

## 8. 分阶段 PR（一项一分支）

| 阶段 | 分支建议 | 内容 | 门禁 |
| --- | --- | --- | --- |
| P1 数据层 | `feat/article-content-map` | 新迁移建表 + 幂等回填脚本（优先复用 `sync-python` 导出通道）+ 映射覆盖率实测报告 | **需三人确认**（新增表结构），且等 #362 的 V31 落定取号 |
| P2 契约 + 后端 | `feat/article-related-works-api` | `openapi.yaml`、`ArticleDtos` / `ArticleService`、批量解析与三条件过滤、`ContractDriftTest` 核对、`check-contract.py` | **需三人确认**（跨模块契约） |
| P3 客户端 | `feat/article-related-works` | model + 详情页横滑区 + widget 测试 | 无门禁，但依赖 P2 上线 |

P1 与 P2 可以各自成 PR；**不要三个阶段的改动堆进一个分支**。P3 的分支本轮已预建、
目前为空，可留用。

## 9. 三人确认决策点（逐项拍，勿代签）

| # | 议题 | 建议初值 | 备选 | 影响 |
| --- | --- | --- | --- | --- |
| D1 | 是否新增映射表 / 字段类型 | 落 `work_content_map(content_id VARCHAR(128), subject_id VARCHAR(128))` | 资讯导入时直接把 `related_work_ids` 改写成 subject_id | 后者改写 V9「原文透传」口径、历史数据要回填、反向查语义受损 |
| D2 | 映射数据来源与更新频率 | 分页遍历 `/api/contents`（遵守限流），手动可重跑 | 直连首站库导出 / 定期 cron | 站点无 SLA，需本地快照兜底；是否需要常驻任务 |
| D3 | `related_works` 形状 | `WorkSummary[]`，复用现有 schema | 新建 `ArticleRelatedWork` DTO | 后者要登记 `ContractDriftTest` 两张表 |
| D4 | 未命中 / 不可展示的 id | 静默丢弃，只给空数组 | 降级为来源站外链卡 | 后者要把 `SITE_BASE_URL` 拼 `/contents/{id}` 引入客户端，且验收口径变成混合 |
| D5 | 顺序与数量上限 | 保持来源站原始顺序，上限 [待定，建议 20] | 按评分 / 匹配度重排 | 重排属「客户端自算」或服务端算法，越出 #408 范围且可能撞 #403 七项 |
| D6 | 迁移号 | #362 的 V31 合并后按 `sort -V` 取下一号（预计 V33） | 与 #401 的 V32 协调互换 | Flyway `outOfOrder=false`，撞号启动失败 |
| D7 | `related_work_ids` 是否保留 | 保留，与新字段并存 | 移除原文字段 | 破坏老客户端兼容与 §5.3 反向查的数据源 |
| D8 | #408 定性变更 | 从「不受门禁的快赢」改为「需三人确认的数据结构 + 契约变更」，同步改 `relation-algorithm.md` §1 / §5.2 / §9.1 | 维持快赢定性，只做外链降级版 | 影响 #403 的排期口径与「不停车」清单 |

## 10. 验收口径

- 资讯详情页出现横滑本地作品卡，逐条点进去是**有效详情**（不 404、不串错作品）。
- 随机抽样校验：展示的每条都满足 `source='bangumi' AND site_listed=1 AND deleted_at IS NULL`。
- 混合场景：`related_work_ids` 为 `null` / `[]` / 全部未命中 / 部分未命中 → 只展示命中的，
  详情接口均 200，正文不受影响。
- `check-contract.py` 通过；`ContractDriftTest` 通过；`python scripts/devtest.py` 对应栈通过；
  客户端 widget 测试覆盖「有 / 无 / 部分命中」三态并带卡片尺寸断言。
- 性能：单条资讯详情不因关联查询产生 N+1（可用 SQL 计数或集成测试断言）。

## 11. 风险与待补证据

- **首站接口无 SLA / 无版本承诺**（`旧站能力复用清单` 一句话结论）→ 映射表要有本地快照与重跑能力，
  不能让资讯详情在运行时依赖首站在线。
- **映射漂移**：首站新增 / 删除作品后映射会过期；命中率与覆盖率需实测，未实测前不要写进验收数字。
- **`site_listed` 白名单会变**：V28 的口径是「库里存全量、app 只显示收录的」，解析必须实时过滤。
- **门禁冲突**：`relation-algorithm.md` §9.1 当前把 #408 列为「不受门禁、可立即推进」；
  若 D8 拍板改定性，需同步更新 §1 表格、§5.2、§9.1 以及 `backend-java/.../ArticleDtos.java:10`
  「客户端第一版不用」的注释。这些文档本轮**未改动**（工作区另有并行编辑，避免覆盖）。
- **既有文档更正**：`relation-algorithm.md` §1 的「数据通 / 展示缺」应改为
  「id 原文已落库，解析链缺失」；§5.2「不动后端结构」应作废。
