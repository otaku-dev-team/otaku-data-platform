# 人物页 / 制作公司页 / 详情页富字段（数据链路方案草案，待三人确认）

> **状态：提案，不含任何代码改动。**
> 涉及**新增后端端点**与 **`Work` 详情字段扩容** = 跨模块契约变更，按
> [`project-charter.md`](project-charter.md) §3.2 属红线，需 @zhengmin486（契约 / 数据侧）
> 与 @pyxz0（W2 跨源、W3 数据）确认后才拆实现 PR。
>
> 上位：W1 计划 [`client-enhancement-plan.md`](client-enhancement-plan.md) §5；
> 差距盘点 [`站点能力差距清单.md`](站点能力差距清单.md) §二 / §三 / §P3。
> 同族提案：[`d3-cross-source-identity-proposal.md`](d3-cross-source-identity-proposal.md)（D3）。

---

## 1. 结论先说

三块**都没做**，实现侧一行代码都没有：库里没有 person / character / studio 任何表，
后端没有对应端点，客户端详情页只有 `tags` 与 `main_rating` 两处富信息。

但**我上一条给出的理由不准确**。我说的是「站点只有 HTML、得先抓 1.8 万次详情页 + 后端新端点」。
实测下来，数据本来就在我们自己的档案里：

| 能力 | 数据在哪 | 实测覆盖率 | 是否需要新数据源 |
|---|---|---|---|
| 原名 / 别名 / 媒介 / 话数 / 放送开始 / 放送星期 | **现有瘦身档 `subject.jsonlines` 的 `infobox`** | 85%–99.7% | **不需要** |
| Staff（导演 / 脚本 / 音乐 / 人物设定 / 动画制作…） | 同上，`infobox` 里的键 | 23%–74% | **不需要** |
| 人物页（姓名 / 参与作品）、角色与声优 | **完整档 `dump.zip`** 的 person / character / subject-persons / person-characters | 待实测 | 需要换一份档案（426 MB） |
| 制作公司页 | 完整档 `person.jsonlines` 里 `type=2`（公司）+ subject-persons | 待实测 | 同上 |
| 系列 | 完整档 `subject-relations.jsonlines` | 待实测 | 同上 |

也就是说：**详情页富字段用今天的档案就能做，一个人物/公司页需要一次 426 MB 下载 + 三张新表；
两条路都不需要打站点、不需要 Bangumi API 令牌。**

## 2. 实测证据（2026-10-23，全量扫 `subject.jsonlines`）

扫描对象：`dump-subject-only.zip`（280,329,424 字节，解压后 `subject.jsonlines` 941.1 MB）。

- `type=2`（动画）共 **31,174** 条；
- **`infobox` 为空：0 条**（一条不缺）；
- `date` 非空 **26,092 条（83.7%）**；
- 单条扫描耗时 14.4 秒（全量 69.6 万条约 5 分钟）。

`infobox` 各键的出现率（分母 31,174）：

| 键 | 覆盖率 | 对应能力 |
|---|---|---|
| 别名 | **99.7%** | 详情页「别名」 |
| 中文名 | **99.6%** | 「原名 / 中文名」 |
| 官方网站 | 96.3% | 「官方网站」 |
| 话数 | **85.7%** | 「话数」 |
| 导演 | **73.8%** | Staff |
| 音乐 | 51.2% | Staff |
| 放送开始 | 47.9% | 「放送开始」 |
| 播放结束 | 46.9% | 「放送结束」 |
| 放送星期 | 46.7% | 「放送星期」 |
| 原作 | 32.1% | Staff |
| 脚本 | 28.5% | Staff |
| 製作 | 27.1% | 制作 |
| 人物设定 | 26.7% | Staff |
| 动画制作 | 23.5% | 「制作公司」（**仅文本，非实体**） |
| 企画 | 17.9% | Staff |

`infobox` 是**原始 wiki 串**，不是 JSON。真实样本（id=253《星际牛仔》）：

```
{{Infobox animanga/TVAnime
|中文名= 星际牛仔
|别名={
[Cowboy Bebop]
[宇宙牛仔]
[赏金猎人]
}
|话数= 26
|放送开始= 1998年10月23日
|放送星期= 星期五
|导演= 渡辺信一郎
|音乐= 菅野よう子
|系列构成= 信本敬子
|人物设定= 川元利浩
|剪辑= 鶴渕友彰 / ビデオ編集：キュー・テック、今塚誠
```

要处理三种语法：`{...}` 多值块、`[链接]` 包裹、`/` 与 `：` 分隔的复合值。
这是本方案**主要的工作量**（有现成实现可参考：`bangumi/wiki-parser-py`）。

## 3. 顺带纠正两处早先结论

**① 「`bangumi_id` 我们 100% 有值」——不准确。**
库里**没有 `bangumi_id` 列**（`V1__init.sql` 只有 `(source, source_id)` 唯一键）。
能用的锚点是：`source='bangumi'` 的行的 `source_id` **就是 subject id**。
otaku_site 那 **15,318 条没有对应关系**——它们既没有 `infobox`，也没法映射到 Bangumi 条目。
跨源映射属探索项 E1 / D3，本方案不碰。

→ 实际影响：富字段只能覆盖 **bangumi 来源的动画（约 3.1 万条）**，覆盖率按全库 57 万条算约 5.4%，
按「动画」这一类算约 2/3。这是必须先说清的口径，否则「覆盖率 99%」会被误读成全库。

**② 「详情页富字段只能抓 HTML 或绕 Bangumi API」——两条都不是最优。**
抓 HTML 是 1.8 万次请求、实测 42% 断连、慢页 >32 秒；Bangumi API 要令牌（W3 已判「暂缓」）。
第三条路是**换一份档案**，本地解析、可重复跑、失败不半途而废。

## 4. 三条路线对比

| | A 抓站点 HTML | B Bangumi 完整档案（推荐） | C Bangumi 官方 API |
|---|---|---|---|
| 请求量 | 1.8 万次详情页 + 人物/公司页 | **0**（一次 426 MB 下载） | 每作品 2–3 次，约 5 万次 |
| 可靠性 | 42% 断连、慢页 >32s | 本地文件，幂等重跑 | 限流 + 需令牌 |
| 覆盖率 | otaku_site 15,318 条全有 | 仅 bangumi 来源 | 仅 bangumi 来源 |
| 依赖 | 站点在线且结构不变 | draft release 下载权限 | `OTAKU_BANGUMI_TOKEN`（未落实） |
| 结论 | 只该在需要 otaku_site 独有字段时用 | **字段最多、成本最低** | 增量补齐时再用 |

A 的唯一优势是覆盖 otaku_site 那 1.5 万条，而它们恰好是**封面 99.6% 有值**的一批——
两个来源各有一半长板，合并属 E1，不在本方案。

## 5. 分阶段方案

### T1 · 详情页富字段（不加实体，只加字段）

- 数据：现有 `subject.jsonlines` 的 `infobox` + `date`，sync 侧解析成字段；
- schema：`work` 表加列（或一张 `work_detail` 竖表，见下）；
- 契约：`Work` 详情加可空字段——**红线，需确认**；
- 客户端：详情页「基本信息」从 10 项扩到 16 项左右；
- 验收：抽 200 条人工核对解析正确率 ≥95%；空值一律 `null`，不写空串、不写「未知」。

**字段与建议列名**：`original_title`（`name`，原文名）、`aliases`（`别名`，多值 → JSON 数组）、
`medium`（`platform`，媒介）、`episode_count`（`话数`，整数）、`broadcast_start` / `broadcast_end` /
`broadcast_weekday`、`official_site`。

**两种 schema 取舍**：
- 加宽 `work` 表：读详情一次查询拿全，代价是列表查询也带着这些列（可以只 select 需要的）；
- 独立 `work_detail` 表：`work` 保持窄，详情页多一次 join。
  → 建议**独立表**：富字段只服务详情页，列表与搜索的索引不该被撑大。

### T2 · 人物 / 角色 / 制作公司（新实体 + 新端点，真正的红线）

- 数据：换用完整档 `dump.zip`（426 MB，9 个 jsonlines，见 §6）；
- schema：`person`（含 `type`：1 个人 / 2 公司 / 3 组合）、`character`、
  `work_person`（职位，来自 subject-persons）、`work_character`（角色类型 + 声优 person_id，
  来自 subject-characters + person-characters）；
- 契约：`GET /api/persons/{id}`、`GET /api/studios/{id}`、`Work` 详情加 `staff[]` / `characters[]`；
- **不导**：`person.comments` / `collects`（评论数、收藏数）——按铁律 2「来源站用户数据与评论不进平台」，
  这类聚合计数同样是用户行为数据，不落库；
- 铁律 1 不受影响：数据来自 Bangumi 公开档案，不碰来源站。

### T3 · 客户端（W1 侧，接口就绪后 1–2 个 PR）

- 详情页「角色与声优」「Staff」两区块（现在整块没有）；
- 人物页 `/persons/{id}`、公司页 `/studios/{id}`：姓名 / 作品列表 / 「配音：角色名」；
- 入口：详情页的演职员条目、`infobox` 里的制作公司。

## 6. 完整档里到底有什么（来源：`bangumi/Archive` README）

| 文件 | 关键字段 | 支撑 |
|---|---|---|
| `subject.jsonlines` | `id` `name` `name_cn` `infobox` `platform` `date` `tags` `score` | T1 全部 |
| `person.jsonlines` | `id` `name` `type`(1人/2公司/3组合) `career` `infobox` `summary` | 人物页、公司页 |
| `character.jsonlines` | `id` `role` `name` `infobox` `summary` | 角色页 |
| `subject-persons.jsonlines` | `person_id` `subject_id` `position` `appear_eps` | Staff |
| `subject-characters.jsonlines` | `character_id` `subject_id` `type`(主角/配角/客串) `order` | 角色列表 |
| `person-characters.jsonlines` | `person_id` `subject_id` `character_id` | **角色 → 声优** |
| `episode.jsonlines` | `subject_id` `sort` `type`(0正篇) `name` `airdate` | 话数精确值、分集 |
| `subject-relations.jsonlines` | `subject_id` `relation_type` `related_subject_id` | 系列 |

现用档案是**瘦身档**（只有 `subject.jsonlines`，268 MB）；完整档 `dump.zip` **426 MB**，
同一个 draft release（`data-bangumi-2026-10-21`），下载需要仓库写权限。

## 7. 未验证项（写方案时不允许含糊）

- **完整档未下载**：person / character / 三张关系表的行数与磁盘占用未知，
  T2 的导入耗时与库体积因此**无法给出数字**；
- `platform` 常量映射未核（实测分布 1:9757 / 3:6574 / 空:5721 / 5:4754 / 2:4209），
  映射表在 `bangumi/common` 的 yaml，做 T1 前需核对；
- `infobox` 解析正确率未测：本文只统计了键的**出现率**，没有校验值的正确性；
- 系列 / 话数的实际可用率未测（需要 `subject-relations` 与 `episode`，两者都不在瘦身档里）。

## 8. 需要确认的三件事

1. **T1 是否放行**：`Work` 详情加 7 个可空字段 + 一张 `work_detail` 表。这条改动小、收益直接
   （详情页从 10 项变 16 项），但仍是契约变更，需要你俩点头。
2. **T2 归谁**：完整档解析属 sync（@pyxz0 的 W2/W3 面），三张表与新端点跨后端与 sync 两侧。
   我可以出 schema 与解析器 PR，但按章程不代笔别人的条目。
3. **口径**：富字段只覆盖 bangumi 来源（约 3.1 万条），otaku_site 那 1.5 万条在 E1 确认前空着——
   客户端要接受「同一条作品，有的有别名、有的没有」，这是数据事实，不是 bug。
