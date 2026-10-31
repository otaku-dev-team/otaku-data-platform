# 人物 id 口径统一（技术范围拆解，待三人确认）

> **状态：调研结论 + 范围拆解，不含任何代码改动。**
>
> 触发：#240 评论里 pyxz0 点名要 sync 侧「按 `person_ref` 统一 + 补 `bangumi_person_id`」；
> [`ROADMAP.md`](ROADMAP.md) 有一行 ⚠️ 记着「数据集侧 `people` 与 `work_cast.person_ref` 是两套 id 空间
> （4,115 个值重叠），直接 join 会挂错名；sync 侧未动」。
>
> 上位：[`person-studio-proposal.md`](person-studio-proposal.md) 的 T2（人物 / 角色 / 公司页）。
> 红线：改数据集 `people.source_id` 的语义 = 跨模块数据结构变更，需三人确认。

---

## 1. 结论先说

`people` 与 `person_ref` **不在同一个 id 空间**：

| 列 | 来源列 | id 语义 |
|---|---|---|
| `people.source_id` | `entities.id` | 网站**本地自增**主键 |
| `work_credits.person_ref` | `content_credits.person_id` | **Bangumi 人物 id** |
| `work_cast.person_ref` | `content_cast.person_id` | **Bangumi 人物 id** |

后端 `people` 已经被 #271 按 `person_ref` 补了 **19,399 行**（`source_id` = Bangumi 人物 id，
`INSERT IGNORE` 只补不覆盖）。所以「把数据集的 `people` 导进后端」不是补数据，而是
**拿另一套 id 去撞已有行**：4,115 个数值相同、指的不是同一个人，撞上就把名字挂错；
又因为只补不覆盖，**错名写进去之后，后来的正确值改不回来**。

统一方向只有两个：

- **A（推荐）** `people.source_id` 改为 Bangumi 人物 id，与 #271 的既有口径对齐；
- **B** 保留 `entities.id`，后端改成 join `people.bangumi_person_id`。
  代价是动已上线的查询，并且「两套 id 约定」会同时存在——A 之后只有一套。

## 2. 证据（逐条可复核）

| # | 位置 | 说明了什么 |
|---|---|---|
| 1 | 首站 `app/models.py:113` | `content_credits.person_id` 注释原文「是 Bangumi 人物 id」 |
| 2 | 首站 `app/bangumi_meta.py:422` | 声优取 `actors[0].id`，即 Bangumi 人物 id |
| 3 | 首站 `app/models.py:1084` | `entities.bangumi_person_id` 是「溯源位」，**infobox 只给名字，暂为 NULL** |
| 4 | 首站 `app/bangumi_meta.py:388` | `build_staff_rows()` 产出的行 `person_id` 恒为 `None` |
| 5 | 首站 `app/bangumi_meta.py:472` | 只有 persons 接口来的长尾 staff 才带 `person.get("id")` |
| 6 | `mappings/otaku.json:71` | `people.bangumi_person_id` ← `entities.bangumi_person_id` |
| 7 | `mappings/otaku.json:78` | `work_credits.person_ref` ← `content_credits.person_id` |
| 8 | `mappings/otaku.json:89` | `work_cast.person_ref` ← `content_cast.person_id` |
| 9 | `ImportService.java:374-386` | 后端只从关系里的 `personRef` 补壳，**没有 people 导入通道** |
| 10 | `WorkRelationRepository.java:143` | `INSERT IGNORE INTO people (source, source_id, …)` 只补不覆盖 |
| 11 | 首站 `local_dev.db` 实测 | `entities` 12 行，`bangumi_person_id` **全部为 NULL**，与 #3 一致 |

## 3. 「`bangumi_person_id` 覆盖 0%」到底是什么

**不是跑错了，是上游从没写过。** `entities` 是 infobox 里的名字花名册，
`bangumi_person_id` 从建表起就没有任何写入路径（#3）。

对称的两处：

| 侧 | 谁能拿到 Bangumi id | 现状 |
|---|---|---|
| 声优（`content_cast`） | `actors[0].id` | **100% 有值** |
| 主创（`content_credits`，infobox 来源） | 无——只有名字文本 | **0%** |
| 长尾 staff（persons 接口） | `person.get("id")` | 有值，但只覆盖 `tier=candidate` |

一句话：**声优能统一，主创不能**——除非补数据源。这条是本次拆解里最该先对齐的事实，
否则会得出「补个字段就完事」的错误预期。

## 4. 改完能拿到什么（阶段 1 的收益边界）

`people` 重键到 Bangumi 人物 id、从关系里派生之后：

- **声优**：`work_cast.person_ref` 全部命中 `people` → 人物页可跳、可按声优聚合；
- **主创**：只有 `tier=candidate` 的长尾能命中，infobox 主创（导演 / 脚本 / 音乐）仍然没有 id，
  人物页对这批人依然是死链。

也就是说：**阶段 1 交付的是「声优侧闭环」，不是「人物页全量可用」。**
主创那一半卡在数据源上，不是卡在代码上。

## 5. 三档范围

### 阶段 1 · sync 侧统一（我们能做，零新数据源）

- `people` 的取数从「照搬 `entities` 表」改为「按 Bangumi 人物 id 派生」：
  声优全量 + `person_id` 非空的 credits 行；
- `people.source_id` 与 `bangumi_person_id` 此时同值（语义冗余，但读方不会猜错）；
- 数据集版本 `v2 → v3`（改了列的语义，必须升版本，见 `schema.py` 的版本约定）；
- 验收：`people` 里每条 `source_id` 都能在 `work_cast.person_ref` 或 `work_credits.person_ref` 找到；
  反向抽 200 条核对「id → 名字」没有张冠李戴。

### 阶段 2 · 主创补 id（pyxz0 / W2·W3 数据面）

infobox 主创要变成可跳转，必须先有 Bangumi 人物 id。两条路：

| 路线 | 成本 | 备注 |
|---|---|---|
| Bangumi Archive `person.jsonlines` 名字匹配 | 无令牌，一次 70 MB | 与 T2 同一份档案，可顺带做 |
| Bangumi persons 接口 | 需 `OTAKU_BANGUMI_TOKEN` | W3 已判「暂缓」，5 万次请求 |

名字匹配有假阳性风险（同名不同人），需要「名字 + 作品交集」双条件校验。
**这块归数据侧，不在 sync 单方面动手范围内。**

### 阶段 3 · 人物端点（契约，红线）

`GET /api/persons/{id}` + `Work` 详情里的 person 载荷。依赖 #125 / #256 拍板，
`openapi.yaml` 目前**没有任何 person 端点**。本方案不碰。

## 6. 需要确认的三点

| | 待确认 | 为什么不能单方面定 |
|---|---|---|
| **D1** | 数据集升 v3：`people.source_id` 语义改为 Bangumi 人物 id | 改的是列的语义，读方按 v2 理解会拿错人 |
| **D2** | 没有 Bangumi id 的 `entities` 行怎么办（**含全部公司行**，公司同样没有 id）：不导，还是另开一条弱关联通道只做名字展示 | 影响主创与制作公司能不能做，也影响要不要新增表 |
| **D3** | 取名优先权：现在是 `INSERT IGNORE` 先到先得，数据集名字更规范时是否允许覆盖 | 属后端改动，且会改变 #271 已回填数据的稳定性 |

## 7. 明确不做

- **不改 #271 已回填的 19,399 行**——那是生产数据，重跑要单独的迁移脚本与对账；
- **不新建人物表**——`people` 已经在了，缺的是口径不是结构；
- **不碰网站用户数据**（铁律 2），人物页只做公开档案；
- **不在阶段 1 顺手补主创 id**——那是阶段 2、另一个人的面。

## 8. 未测项（写方案时不允许含糊）

- **生产库的真实量拿不到**：本机只有 11 部作品的 dev 库（`content_cast` 0 行、`content_credits` 0 行），
  量不出「声优去重后多少人」「`entities` 多少行」「4,115 重叠的实际影响面」。
  要数字得连生产库或跑一次 `sync --coverage-report --source-db <库>`；
- **名字匹配的准确率未测**：阶段 2 的双条件校验是设计，不是实测结果；
- **`entities` 里有没有声优**：从写入路径看只有 `ENTITY_ROLE_MAP` 那几个主创职位
  （导演 / 系列构成 / 音乐 / 角色设计 / 原作 / 动画制作），推断不含声优——生产库没核过。
