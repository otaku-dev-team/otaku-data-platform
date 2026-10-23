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
| 原名 / 别名 / 话数 / 放送信息 / Staff | **现有瘦身档 `subject.jsonlines` 的 `infobox`** | **动画**：话数 85%、中文名 74%、别名 51%、导演 57%（口径见 §2） | **不需要** |
| 漫画 / 小说 / 游戏的同类字段 | 同上，但「键齐全、值为空」 | 中文名 15%–32%、话数 0%–14% | 要支持得另做字段映射 |
| Staff（导演 / 脚本 / 音乐 / 人物设定 / 动画制作…） | 同上，`infobox` 里的键 | 动画：导演 56.8% / 原作 32.0% / 脚本 28.4% / 音乐 24.1% | **不需要** |
| 人物页（姓名 / 参与作品）、角色与声优 | **完整档 `dump.zip`** 的 person / character / subject-persons / person-characters | Staff 覆盖 **77.3%**、角色 39.3%、声优 33.7%（§6.1） | 需要换一份档案（426 MB） |
| 制作公司页 | 完整档 `person.jsonlines` 里 `type=2`（公司）+ subject-persons | **8,465 家公司**，staff 涉及 54,968 个实体 | 同上 |
| 系列 | 完整档 `subject-relations.jsonlines` | 85,063 条，覆盖动画 **64.1%** | 同上 |

也就是说：**详情页富字段用今天的档案就能做，一个人物/公司页需要一次 426 MB 下载 + 三张新表；
两条路都不需要打站点、不需要 Bangumi API 令牌。**

## 2. 实测证据（2026-10-24，全量扫 `subject.jsonlines`）

扫描对象：`dump-subject-only.zip`（280,329,424 字节，解压后 `subject.jsonlines` 941.1 MB）。
分类按入库规则：`type=2` 动画、`type=4` 游戏、`type=1` 且 `platform=1001/1002` 分别算漫画 / 小说。

**先讲一个我第一版写错的地方**：`infobox` 的**键几乎每行都有**（模板会把所有参数都列出来），
但**值是空的**——「键出现率」不是覆盖率。第一版把 99.6% 当成「中文名可用率」写进去，
实际有值的只有 73.8%。下面两个口径分开给。

### 2.1 动画（31,174 条）

| 键 | 有值率 | 对应能力 |
|---|---|---|
| 话数 | **85.2%**（其中 81.6% 是纯整数；1,113 条是「12话」「全24话」这类写法） | 「话数」 |
| 中文名 | **73.8%** | 「中文名」 |
| 导演 | **56.8%** | Staff |
| 别名 | **50.6%** | 「别名」 |
| 放送开始 | 47.4%（其中 2,332 条不是 `YYYY年M月D日` 写法） | 「放送开始」 |
| 官方网站 | 37.5% | 「官方网站」 |
| 原作 | 32.0% | Staff |
| 脚本 | 28.4% | Staff |
| 播放结束 | 25.3% | 「放送结束」 |
| 放送星期 | 24.7% | 「放送星期」 |
| 音乐 | 24.1% | Staff |
| 动画制作 | 23.4% | 「制作公司」（**仅文本，非实体**） |
| `date`（字段，不在 infobox 里） | 83.7% | 兜底年份 |

### 2.2 另外三类：键齐全，值大多为空

| 类型 | 条数 | 中文名 | 别名 | 话数 | 该类型**真正有值**的字段 |
|---|---|---|---|---|---|
| 漫画 | 320,631 | 14.7% | 10.2% | 14.4% | 出版社 99.9% / 发售日 99.8% / 页数 99.2% / ISBN 99.4% / 作者 |
| 小说 | 87,116 | 15.7% | 6.8% | 2.9% | 出版社 100% / 发售日 99.9% / 页数 99.3% / 作者 98.6% |
| 游戏 | 117,295 | 32.2% | 25.4% | 0% | 发行日期 99.9% / 平台 99.8% / 游戏类型 99.7% / 开发 84.6% |

抽样原文（漫画 id=100）：`|中文名= ` 空、`|别名={}` 空，只有
出版社 / 价格 / 发售日 / 页数 / ISBN / 作者 有值——**不是解析问题，是上游没填**。

**结论**：T1 的实际收益集中在**动画这 3.1 万条**。要覆盖其余三类，得再配一套字段映射
（漫画/小说：出版社、发售日、页数、ISBN、作者；游戏：平台、类型、发行日期），
那是另一份工作量，不该塞进 T1。

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

⚠️ 更正：完整档**不在我们的 draft release 里**（那里只有 `dump-subject-only.zip`），
要从上游 `github.com/bangumi/Archive` 的 `archive` 标签下载。最新一版 `dump-2026-10-20.zip` 是 426.7 MB。

### 6.1 完整档实测（2026-10-24，直接扫包，未解压落盘）

| 文件 | 解压后 | 行数 | 对动画 31,215 条的覆盖 |
|---|---|---|---|
| `subject.jsonlines` | 944 MB | — | — |
| `person.jsonlines` | 70 MB | 104,055（公司 `type=2` **8,465**） | — |
| `character.jsonlines` | 157 MB | 224,679 | — |
| `subject-persons.jsonlines` | 150 MB | — | **Staff 1,085,840 条，覆盖 24,120 部（77.3%），平均 45 条/部** |
| `subject-characters.jsonlines` | 27 MB | — | 角色 176,284 条，覆盖 12,254 部（39.3%） |
| `person-characters.jsonlines` | 23 MB | — | 声优关系 292,429 条，覆盖 10,509 部（33.7%），10,387 位声优 |
| `episode.jsonlines` | 325 MB | — | 正篇 342,720 集，覆盖 26,008 部（83.3%），平均 13.2 集 |
| `subject-relations.jsonlines` | 72 MB | — | 85,063 条，覆盖 20,003 部（64.1%） |
| `person-relations.jsonlines` | 15 MB | — | 人物/角色之间的关系，本方案不用 |

**这张表回答了 T2 值不值得做**：

- **Staff 覆盖 77.3%，是这一档里最强的一块**——比 infobox 的「导演 56.8%」更高，而且是结构化的
  （`person_id` + `position`），能直接连到人物页；
- 角色声优只有 33.7%：「有就有、没有就没有」，界面上不该承诺「每部都有声优表」；
- 话数用 `episode` 能到 83.3%，与 infobox 的 85.2% 相当，但 `episode` 更准（能区分正篇 / SP）。

## 7. 未验证项（写方案时不允许含糊）

- **导入耗时与库体积仍未实测**：行数已知（关系表合计约 170 万条），但没真跑过导入，
  磁盘增量与耗时给不出数字——这是 T2 开工前唯一还缺的数；
- `platform` 常量映射未核（实测分布 1:9757 / 3:6574 / 空:5721 / 5:4754 / 2:4209），
  映射表在 `bangumi/common` 的 yaml，做 T1 前需核对；
- `infobox` 解析**正确率只测到「结构」层面**（话数能否转整数 81.6%、放送开始是否符合日期写法），
  没有逐条人工核对语义（例如链接文本、多值去重、`/` 与 `：` 分隔的复合值）；
- 系列可用率未测（需要 `subject-relations`，不在瘦身档里）；话数已测（见 §2.1），但只测了 infobox 里的 `话数`，没和 `episode` 表核对。

## 8. 需要确认的三件事

1. **T1 是否放行**：`Work` 详情加 7 个可空字段 + 一张 `work_detail` 表。这条改动小、收益直接
   （详情页从 10 项变 16 项），但仍是契约变更，需要你俩点头。
2. **T2 归谁**：完整档解析属 sync（@pyxz0 的 W2/W3 面），三张表与新端点跨后端与 sync 两侧。
   我可以出 schema 与解析器 PR，但按章程不代笔别人的条目。
3. **口径**：富字段只覆盖 bangumi 来源（约 3.1 万条），otaku_site 那 1.5 万条在 E1 确认前空着——
   客户端要接受「同一条作品，有的有别名、有的没有」，这是数据事实，不是 bug。
