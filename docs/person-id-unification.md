# 人物 id 口径统一（决策已定，口径见 §6）

> **状态：调研结论 + 范围拆解 + 已定案的口径。D1 / D2 / D3 三项已拍板（§6）。**
>
> 触发：#240 评论里 pyxz0 点名要 sync 侧「按 `person_ref` 统一 + 补 `bangumi_person_id`」；
> [`ROADMAP.md`](ROADMAP.md) 有一行 ⚠️ 记着「数据集侧 `people` 与 `work_cast.person_ref` 是两套 id 空间
> （4,115 个值重叠），直接 join 会挂错名；sync 侧未动」。
>
> 上位：[`person-studio-proposal.md`](person-studio-proposal.md) 的 T2（人物 / 角色 / 公司页）。
> 红线：改数据集 `people.source_id` 的语义 = 跨模块数据结构变更 —— 本次由三方拍板后落地，
> 不是 sync 单方面改（§6 记录了定的是哪几条）。

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

### 生产导出实测（2026-10-27，数据集 v1）

服务器上留着一份当天的导出报告（`/opt/otaku/data/dataset/otaku.db.report.json`），是 v1 口径的真实数字：

| 表 | 行数 |
|---|---|
| `works` | 18,828 |
| `work_credits` | 407,900（`person_ref` 为空 **71,083 行 = 17.4%**） |
| `work_cast` | 75,731（报告未列空值，即无空值） |
| `work_studios` | 4,271 |

这张表纠正一个很容易读错的地方：**「credits 里有 17.4% 没有 id」不等于「主创没有 id」**。
反过来才对——带 id 的是多数，而那是声优和 `tier=candidate` 的长尾 staff 撑起来的；
真正没有 id 的是 infobox 解析出的那一批（导演 / 脚本 / 音乐，`bangumi_meta.py:388` 恒 `None`），
行数不多，却是详情页正面显示的那几个名字。写方案时按行数比例判断「主创有没有 id」会得出相反的结论。

v1 的 `work_credits` 是整表照搬（v2 才加 role 白名单），所以 407,900 不是「详情页用得上的量」。
按 `tier` 的分布还没测到，见 §9。

## 4. 改完能拿到什么（阶段 1 的收益边界）

`people` 重键、从关系里派生、并补上弱关联之后：

| 谁 | 能做什么 | 不能做什么 |
|---|---|---|
| **声优**（`bgm:`） | 人物页可跳、可按人聚合、跨源认成同一个人 | — |
| **长尾 staff**（`bgm:`，`tier=candidate`） | 同上 | 覆盖只到 `tier=candidate` |
| **infobox 主创**（`name:`） | 有作品列表、有页面、能被点开 | 不能跨源合并、不能断言同名是同一个人 |
| **公司**（`name:`） | 公司页 `/api/studios/{name}`、作品列表 | 同上，且公司永远不会有 Bangumi 人物 id |

也就是说：**阶段 1 之后没有死链了**——任何人都能点开看到作品列表，区别只是
「能不能断言这是同一个人」。这一点比「声优侧闭环」更进一步，也是 D2 选弱关联换来的。

## 5. 三档范围

### 阶段 1 · sync 侧统一（我们能做，零新数据源）

`people` 的取数从「照搬 `entities` 表」改为「从关系表派生 + `entities` 补名字」，
按 §7 的前缀规则给主键：

- `bgm:<id>`：声保全量 + `person_id` 非空的 credits 行（声优实测 100% 有值）；
- `name:<归一化名字>`：credits / cast 里出现但拿不到 id 的人名，加上 `entities` 里没有 id 的行
  （含全部公司行，`entity_type=company`）；
- `people.name` 优先取 `entities.name`，取不到用关系表里的 `name` / `actor` 原值；
- `work_credits.person_ref` / `work_cast.person_ref` 按同一规则改写成 `bgm:` 或 `name:` 键，**不再留空**；
- 数据集版本 `v2 → v3`（改了列的语义，必须升版本，见 `schema.py` 的版本约定）；
- 验收：关系表里每一个 `person_ref` 都能在 `people.source_id` 找到（**100%，不是 ≥99%**），
  反向抽 200 条核对「id → 名字」没有张冠李戴；另抽 50 条 `name:` 键核对没有把明显不同的人并进来。

> 收益边界仍然要说清：阶段 1 之后**所有人和公司都能被引用、都能出作品列表**，
> 但只有 `bgm:` 那批能跨源合并、能被标成「同一个人」。`name:` 那批只能站内聚合。

### 阶段 2 · 主创补 id（pyxz0 / W2·W3 数据面）

infobox 主创要变成可跳转，必须先有 Bangumi 人物 id。两条路：

| 路线 | 成本 | 备注 |
|---|---|---|
| Bangumi Archive `person.jsonlines` 名字匹配 | 无令牌，一次 70 MB | 与 T2 同一份档案，可顺带做 |
| Bangumi persons 接口 | 需 `OTAKU_BANGUMI_TOKEN` | W3 已判「暂缓」，5 万次请求 |

名字匹配有假阳性风险（同名不同人），需要「名字 + 作品交集」双条件校验。
**这块归数据侧，不在 sync 单方面动手范围内。**

### 阶段 3 · 人物 / 公司端点（契约，**形状照首站**）

口径已定：**网站（首站 `E:\projects\acgn-test-platform`）有什么，我们就有什么，形状照抄。**

| 首站 | 键 | 我们对应 | 说明 |
|---|---|---|---|
| `GET /cast/{person_id}` | **Bangumi 人物 id** | `GET /api/persons/{id}` | 同名同义，`{id}` 就是 Bangumi 人物 id |
| `GET /studios/{name}` | **公司名字** | `GET /api/studios/{name}` | 公司从来没有 id，只能按名字 |
| `GET /creators` | — | `GET /api/persons`（索引，可后置） | 花名册 + 按关联作品数排序 |

首站 `cast_detail()` 的响应形状（`app/business_pages.py:1016`）是**按作品合并**的，
不是「credits 一个列表 + cast 一个列表」：

```
{
  personId, personName,
  works: [                       # 每部作品一条，按评分倒序
    { work: {...},               # 作品摘要
      characters: ["猫猫"],       # 配音的角色（多角色会重复出现在同一部里）
      roles: ["导演"] }           # 制作职责
  ],
  castCount, creditCount
}
```

`/api/persons/{id}` 按这个形状定，`openapi.yaml` 目前**没有任何 person 端点**，
新增属契约变更，随阶段 3 单独开 PR、三人确认（#125 的 T2 已列过同一件事）。

依赖：阶段 1 先让 `person_ref` 能对上 `people`，否则端点是空壳。

## 6. 已定案

| | 决定了什么 | 定成 |
|---|---|---|
| **D1** | 数据集升 v3：`people.source_id` 语义改为 Bangumi 人物 id | **照做**。与 #271 的既有口径对齐，之后只有一套 id 约定（方案 A） |
| **D2** | 没有 Bangumi id 的 `entities` 行（含全部公司行）怎么办 | **另开弱关联通道**。判据是「网站有的我们不能没有」——首站的公司页 `/studios/{name}` 就是按名字做的，我们照做，不因为拿不到 id 就把这批人/公司丢掉 |
| **D3** | 取名优先权：`INSERT IGNORE` 先到先得，数据集名字更规范时可否覆盖 | **保持先到先得**，本期不改后端取名逻辑。名字规范化放在数据侧解决（导出前归一），不引入覆盖语义 |

附带两条同时定了：

- **人物端点形状跟首站**，见 §5 阶段 3 的表；
- **账号注销走「去标识化」**（保留内容、抹掉可识别身份），不做物理删除——
  这条属 UGC 侧（pyxz0 的 B2c⑤ 已按「默认匿名化保留」实现），此处只记录口径，
  不在人物链路里做任何额外动作。

## 7. 弱关联通道怎么落地（D2 的展开）

**不新建表。** 弱关联的键是**名字**，而名字本来就在关系表里
（`work_credits.name` / `work_cast.actor` / `work_studios.name` 都是 `NOT NULL`）。
缺的不是结构，是「一个能被引用的人/公司是谁」。

做法：`people` 表用**主键前缀区分强弱**，一张表装两类身份。

| 前缀 | 什么情况 | `bangumi_person_id` | 能做什么 |
|---|---|---|---|
| `bgm:<人物id>` | 声优（实测 100% 有值）、`tier=candidate` 的长尾 staff、以及阶段 2 补到 id 的主创 | 填 | 跨源合并、人物页可跳、可按人聚合 |
| `name:<归一化名字>` | infobox 主创（导演 / 脚本 / 音乐）、**全部公司行** | 空 | 站内按名字聚合：作品列表、公司页 |

`work_credits.person_ref` / `work_cast.person_ref` 一律指向这两种键之一，**不再留空**。
关系表 join `people` 因此恒为 100% 命中，前端不用再判断「这个字符串是 id 还是名字」。

三条必须写明的边界：

1. **弱关联只做聚合，不做身份合并。** `name:佐藤` 下的作品可能是两个同名人演的，
   页面可以并列展示，但不能断言「这是同一个人」。强关联才允许断言。
2. **名字要归一化后再做键**：全半角、首尾空白、连续空白折叠。不做这一步，
   「柿原優子」和「柿原優子 」（尾空格）会分成两条，聚合直接分叉。
3. **前缀是数据约定的，不是数据库约束。** 读方按 `bgm:` / `name:` 分支，
   无法识别的键按弱关联处理（宁可少合并，不可错合并）。

公司侧同理，但更简单：`work_studios.name` 就是键，公司页 `/api/studios/{name}`
直接按名字查，不需要经过 `people`。

## 8. 明确不做

- **不改 #271 已回填的 19,399 行**——那是生产数据，重跑要单独的迁移脚本与对账；
- **不新建人物表**——`people` 已经在了，缺的是口径不是结构；弱关联也没有新表（§7）；
- **不碰网站用户数据**（铁律 2），人物页只做公开档案；
- **不在阶段 1 顺手补主创 id**——那是阶段 2、另一个人的面；
- **不做物理删除**——注销走去标识化，与 UGC 侧口径一致（§6 附带条）。

## 9. 未测项（写方案时不允许含糊）

- **生产库已跑通（2026-11-01）**：站点库 `/opt/acgn-test-platform/local_dev.db`（118 MB，库里就是线上数据，
  文件名带 `local_dev` 是历史遗留），`/opt/acgn-test-platform/backups/` 下有每日快照。
  运维通道禁止 sqlite 直连，但最终通过云助手（TAT）在机器上跑了 `scripts/person-coverage.py`，
  数据即 10-27 那次导出对应的线上状态（用户确认 27 日后网站无大更新，数字当前有效）。

  | 来源 | 位置 | 结果 |
  |---|---|---|
  | dev 库 | `E:\projects\acgn-test-platform\local_dev.db` | `entities` 12 行（11 person + 1 company）、三张关系表 0 行 |
  | 生产库 | `/opt/acgn-test-platform/local_dev.db` | ✅ 2026-11-01 跑通 person-coverage，见下表 |
  | 生产导出报告 | `/opt/otaku/data/dataset/otaku.db.report.json` | ✅ 行数与空值率已取，见 §3 |
  | 数据集 v2 | `sync-python/runs/dataset-local-v2.db` | `people` 12 行（带 `bangumi_person_id` 0 行）、关系表引用 0 个 id |

  **生产实测（`person-coverage.py`，2026-11-01，源库 v1 口径）**：

  | 维度 | 指标 | 数字 |
  |---|---|---|
  | 声优 coverage | `content_cast` 总行数 / 有 person_id / 无 person_id | 75,821 / 75,821 / **0（100%）** |
  | 声优去重 | 去重 person_id / 去重 actor 名（归一后） | 6,677 / 6,674 |
  | 主创 coverage | `content_credits` 总行数 / 有 id / 无 id | 408,144 / 336,979（82.6%）/ 71,165（17.4%） |
  | 主创去重 | 去重 person_id / 去重 name（归一后） | 19,678 / 49,235 |
  | 弱关联同名 | 归一后重名的人名个数（无 id 的 credits 中同名 >1 次） | **10,773** |
  | 花名册 | `entities` 总行数（person / company） | 17,916（14,223 / 3,693） |
  | 花名册字段 | `entities` 有 `bangumi_person_id` | **0（全部 NULL）** |
  | 公司 | `content_studios` 总行数 / 去重公司名 | 4,269 / 1,604 |
  | 两套 id 撞车 | `entities.id ∩ cast.person_id` | 2,514 |
  | 两套 id 撞车 | `entities.id ∩ credits.person_id` | 2,949 |
  | 关系表覆盖作品 | 有 credits / 有 cast / 有 studios（共 contents 18,828） | 10,865 / 8,022 / 3,643 |

  原「未测」的四项现在都齐了：**按 tier 的 id 分布**（声优 100% / 主创 82.6%）、**entities 行数**（17,916）、
  **两套 id 撞车数**（2,514 + 2,949 = 5,463，比 ROADMAP 记的 4,115 更全）、**归一后同名重复率**（10,773 个重名人名）。
- **名字匹配的准确率未测**：阶段 2 的双条件校验是设计，不是实测结果（保留未测）；
- **`entities` 里有没有声优**：生产库实测 `entities.entity_type=person` 14,223 行且 `bangumi_person_id` 全 NULL，
  写入路径只覆盖主创职位（导演 / 系列构成 / 音乐 / 角色设计 / 原作 / 动画制作），**确认不含声优**——与「声优 id 来自 `actors[0].id`」一致；
- **`name:` 弱关联的实际重复率**：已测。无 id 的 credits 里归一后重名的人名 **10,773 个**，即弱关联通道会把同名不同人的条目并到同一 `name:` 键下；
  量级占无 id 主创 71,165 行的约 15%（其余为各自唯一的人名），说明弱关联合并不可避免但规模可控，通道「看起来准不准」有了基线。
