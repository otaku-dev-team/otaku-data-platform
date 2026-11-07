# 关联算法重构提案（草稿 v0.1）

> 状态：草稿，供团队对齐。涉及数据结构 / 数据契约的条目需**三人确认**，本文件不代签。
> 关联：epic「算法（重中之重）」、#373（纯规则原型，已 MERGED）、#383（rating_count 回填，已完成）、#393（后端阈值，已合并）。
> 与 `algorithm-design.md` 的关系：主文档管「画像 / 推荐引擎」，本文件专攻「关联 / 相似」子域（作品↔作品、资讯↔作品、实体关联、系列）。

## 0. 背景与边界

- **用户原话**：关联算法（作品间、资讯↔作品、实体关联）首站（我们参考的源站 acgn-test-platform）做得一般，可参考不照搬，要优化甚至重构。
- **项目红线（章程）**：纯规则、可解释、按站烘焙；不引模型、不写 `otaku` 硬编码、不照搬来源站未定口径。
- **客户端只渲染、不自算**：打分与聚合在服务端（与 `algorithm-design.md` §6 一致）。

## 1. 现状实证（代码核对，2026-11-04）

| 关联场景 | 后端 | 前端 | 结论 |
| --- | --- | --- | --- |
| 作品↔作品（详情页"相关作品"） | ✅ `WorkService.related` + `WorkRepository.findRelated`（`JSON_OVERLAPS` 标签 + `rating_value` 降序） | ✅ `related_works_section.dart` + 完整 repo/datasource/Hive 缓存链 | 已实现 |
| 制作人员 / 声优（作品详情正向） | ✅ `work_staff` / `work_characters` 表 + `WorkRelationRepository` 落库 | ✅ `work_credits_section.dart`（折叠 6 条） | 已实现（正向） |
| 制作公司（正向） | ✅ `work_studios` 表 | ✅ `work_detail_page.dart` 用 `MetaLine` 展示 | 已实现（正向） |
| 人物 / 公司 → 作品（反查） | ❌ 无 `person→works` 查询 | ❌ **无人物页**（`person_id` 注释明写"不参与交互、人物页在 B2 范围外"） | **缺失** |
| 资讯→作品 | ✅ DTO `relatedWorkIds` 已落库、`ArticleService` 已读 `related_work_ids` | ❌ `article_detail_page.dart` 完全未渲染（grep 仅命中 model / mock 空数组） | 数据通 / 展示缺 |
| 作品→资讯（相关资讯） | ❌ work 上下文无任何 `article` 引用 | ❌ | **缺失** |
| 系列关联 | ❌ 后端无 series 概念（全文仅 `java.util.Collections`、`Batch` 等无关词） | ❌ | **缺失** |

**更正说明**：上一轮评估曾把"实体关联缺失"一笔带过，实际是**正向数据 + 展示齐全**（作品→人员/公司），缺的是**反向**（点人物看其作品）与**人物页**。参考站有这层反查，我们没有。

## 2. 现有算法具体毛病

**作品↔作品（我们自己的实现）：**
1. 用全站 `rating_value` 排序而非匹配度加权——同标签池里高分老番永远占满位置，匹配质量低。
2. 不区分共享标签数量 / 权重——1 个标签重叠和 5 个重叠并列进候选。
3. 展示理由与实际命中不一致——前端写"同题材：作品自身标签"，SQL 命中却是所有重叠标签。
4. 缺首站那套硬规则：避雷一票否决、剔除已看 / 已藏、系列去重——我们都没有。
5. 无新鲜度 / 近期维度，也无曝光记录（无法评估、无法 A/B）。

**其余场景：**
- 资讯→作品：**已定方案，不走映射表**——`article.related_work_ids` 现存的是网站 content_id（`/contents/{id}`），与 `work_id` / subject_id 是两套号。2026-11-05 生产实测后改由**数据侧在导出时 JOIN 成 bangumi subject_id** 再写入（首站 `article_content_links` 3,473 行 100% 可解析，893/1,050 篇有关联），后端零改动、无需新表。见 §5.2 与 #422 的变更通知。
- 作品→资讯、系列关联、实体反查：尚未实现。

## 3. 外部借鉴（GitHub 真实项目，不照搬）

> 下列均为公开仓库，取"结构思路"、不取"代码 / 数据 / 模型"。

| 项目 | 可借鉴 | 不照搬 |
| --- | --- | --- |
| **MAL-Recommender** | 混合 70% 内容（genres / studios / authors）+ 30% 协同；Jaccard 用户匹配；偏好系统（收藏 genre、排除不喜欢、最小分阈值）；studio 作为内容特征 | 它的数据源是 MyAnimeList；我们按站烘焙、不接外部账号 |
| **asoron/AnimeMangaRecomandadtion** | 自编码器 latent + cosine，**相似度优先、人气(members) / 评分作决胜**——正是我们要修的"评分排序"毛病的正解 | 自编码器属"模型"，违反纯规则红线，只取其"排序结构" |
| **paras603/anime-recommendation** | TF-IDF 标签向量 + cosine KNN——等价于标签集合的重叠度度量 | 单标签稀疏场景效果有限，我们改用加权重叠 |

**提炼出的 4 条可迁移模式：**
1. **相似度优先、评分 / 人气作决胜**：修正"全站评分排序"——匹配度主导候选，评分仅作同分时决胜。
2. **标签 / 类型集合的重叠度度量**（Jaccard / cosine），而非"共享 ≥1 标签即候选"——升级为加权重叠。
3. **偏好 + 排除 + 阈值机制**：对应我们的避雷一票否决、去已看 / 已藏、`rating_count` 阈值。
4. **实体（studio / 主创）作为内容特征参与相似**：支撑"实体反查"（人物 / 公司 → 作品）方向。

## 4. 目标架构：召回 / 打分 / 排序 分离

```
            多路召回 (Recall)
   ┌────────────┼────────────┐
 标签重叠    同系列    同实体    同资讯关联 / 共现
   └────────────┼────────────┘
                ▼
            打分 (Score)
  matchScore = 标签重叠加权 + 实体命中 + 系列命中
  决胜: rating_value；一票否决: 避雷；去: 已看/已藏；系列去重
                ▼
            排序 (Rank)
  score 降序 → Top-N，附带 reasons[] 可解释
                ▼
          客户端只消费，不自算
```

与 `algorithm-design.md` §4 规则引擎、`§5` 推荐 API 共用同一套 `score` / `reasons` 契约。

## 5. 分场景算法

### 5.1 作品↔作品（核心，重构重点）
- **召回**：`JSON_OVERLAPS` 候选 → 升级为"共享标签数 / 权重 ≥ k"。
- **打分**：`matchScore = Σ(命中标签权重) + 实体命中(同 studio / 主创) + 系列命中`；同分时以 `rating_value` 决胜。
- **硬规则**：避雷一票否决；剔除已看 / 已藏；系列去重（同系列只留代表作）。
- **理由**：实际命中的标签 / 实体 / 系列，而非"作品自身标签"——修正展示不一致。

### 5.2 资讯→作品（P0，**数据侧 JOIN + 服务端解析，均已落地**）
- 现状：`article.related_work_ids` 存的是网站 content_id，**不是 `work_id`**；`V28` 已把 otaku_site 那批真软删，直接按 content_id 接 work 会全是 404 死链。
- **方案（2026-11-05 生产实测后定）**：数据侧导出时 JOIN 出 **bangumi subject_id** 写进 `related_work_ids`（#438），后端解析只剩一句
  `work.source_id in (...)`，外加 `source='bangumi'` + `site_listed=1` + `deleted_at IS NULL` + `is_adult=0`，一次 `IN` 禁 N+1、**按原序重排**；客户端只渲染 `related_works: WorkSummary[]`。
- **服务端落点**：`ArticleDetailAssembler`（不塞进 `ArticleService`——解析口径只在作品侧有一份，
  而 `WorkService` 又依赖 `ArticleService`，互相注入就成环）。`related_works` 的三态：
  `null` = 语义开关未切（不解析）/ `[]` = 切了但没有可用作品 / 非空 = 解析结果。
- **不需要**：`work_content_map`、分页遍历 `/api/contents`、限流记账、失败页重跑、快照兜底。
- 反向查（#409）同样不需要映射表：`related_work_ids` 里已是 subject_id，直接按包含关系匹配。
- **更新频率**：资讯每日更新、新番档期与作品按季度更新。JOIN 方案每次导出都从源库实时取，季度新增作品自然被下一次导出带出来，不需要维护映射增量（这正是它比映射表强的地方）。新番同样带 `bangumi_id`（zm 确认，编辑流程保证）。

### 5.3 作品→资讯（相关资讯，P0，**已落地** `GET /api/works/{work_id}/articles`）
- 做法：`JSON_CONTAINS(article.related_work_ids, …)` 反查含本作品 subject id 的资讯，
  按 `published_at DESC, id DESC` 分页（复用 `ArticlePage` 形状，不新造 DTO）。
- 只对 `source='bangumi'` 的作品成立：`related_work_ids` 是 bangumi subject id，
  其它来源的 `source_id` 是另一套号，拿去匹配会撞号（V28 实测 3,015 条假匹配），所以非 bangumi 直接返回空、不查库。
- **语义开关**：`article.related_ids_semantic`（`app_config`，缺省 `content_id`）。
  切流前库里还是 content_id，按 subject id 匹配会把**别的作品**的资讯挂上来且不报错；
  数据侧 publisher 切换后把它置 `subject_id` 即生效，不用发版。切流前接口返回空。
- 存储形态两种都匹配：`["11972"]`（Java 导入的 `List<String>`）与 `[11972]`
  （数据侧从 SQLite 读出的整数）——`JSON_CONTAINS` 对类型敏感，只写一种会有一半数据静默查不到。
- 没有为 JSON 列建索引：article 当前千级行，全表扫毫秒级；上万再考虑 `(article_id, subject_id)` 反查表。

### 5.4 系列关联（P1，**已落地 2026-11-07**）
- 引入 series 概念（清单 / 关系表），详情页「系列作品」区。
- **实现**（#411 / PR 见 issue）：
  - `V37`：`work.series_key` + `idx_work_series (series_key, release_year)`；`series(series_key, name)` 独立表。
  - 导入：`ImportItem` 新增 `series_key` / `series_name`（**只有数据集通道给**，站点 REST 通道省略 = 不覆盖）；
    导入时先 upsert 系列行、再写作品归属，同一事务。
  - 反查：`GET /api/works/{work_id}/series` → `{series_key, series_name, items}`；
    按年代升序（观看顺序语义，不按评分）、**包含当前作品**、排除已下架/未收录/成人。
  - 数据集侧：`publisher` 从 `works.series_key` + `series.name` 取值随作品一起提交。
- 没做：系列名缺失时的兜底命名、跨来源系列归并（各站系列 id 不同，归并属于 W2 的跨源身份问题）。

### 5.5 实体反查（人物 / 公司 → 作品，P1）
- 利用现有 `work_staff` / `work_characters` / `work_studios` 建反向索引（实体 → 作品列表）。
- 人物页（B2 范围外）暂缓，但反向列表接口可先沉淀，供将来人物页 / 制作公司页复用。
- **依赖 #362 v3 人物前缀键落地**：person_id 带 `bgm:`（强关联）/ `pname:`/`cname:`（弱关联）前缀，#412 后端按前缀判强弱关联；#362 在三人确认 + 列宽 A/B 决策（见 #403 §7）后合入。

### 5.6 资讯↔资讯（可选，P2）

**已实现（2026-11-06，#414）**：`GET /api/articles/{articleId}/related?limit=10`（公开读）。

- 召回：**共享标签**（`JSON_OVERLAPS`）或**同分类**；
- 打分：`共享标签数 × 2 + 同分类 × 1`，同分按发布时间倒序；
- **同来源不计分**：一个来源每天几十条，按来源召回等于「只要是这家写的就相关」，
  会把真正同题材的旧文挤掉——噪声大于信息；
- 源资讯不存在 404；无相关 200 + 空 `items`（客户端整块不渲染）。

> 原方案写的是「同标签 / 同来源共现」，落地时把同来源降级为不参与打分，理由如上。

## 6. 分阶段路线

- **P0**：作品↔作品打分由"评分排序"改为"匹配度 + 评分决胜"（修 `WorkRepository.findRelated` / `WorkService.related`）；资讯↔作品（#408/#409）**改在数据侧**（导出时 JOIN 成 subject_id）+ 服务端一次 `IN` 解析（无新表、无迁移），见 §5.2。
- **P1（补场景）**：系列关联数据结构 + 反查接口；实体反查列表接口（人物页暂缓排期）。
- **P2（沉淀）**：召回 / 打分 / 排序统一服务，曝光记录埋点（为 A/B 与权重调优打底）。

> **依赖澄清（2026-11-04 #401 实测后，2026-11-05 两次更正）**：本提案 P0 里，**#407 作品↔作品标签打分**为内容 / 标签驱动、不依赖行为信号，可先推；**#408/#409 资讯↔作品**不依赖行为信号，2026-11-05 生产实测后**确认不需要 `work_content_map`**（首站 `article_content_links` 100% 可解析），改由数据侧导出时 JOIN，**后端只多一次解析（无新表、无迁移）**——但需等数据侧 publisher 切换完成，切流后 `related_works` 才有值。P2 的 #413（统一服务含行为信号）与整体推荐（#402）原受 `#240` 浏览采集 + 真实用户数据卡，**现开发期可用「模拟用户行为数据」种子先行开发**（zm 决策，生产期再接真实信号，开关隔离）——详见 `algorithm-design.md` §8。#412（实体反查）依赖 #362 v3 人物前缀键落地 + 列宽 A。

## 7. 决策日志（跨模块，需三人确认）

> 决策要点与建议初值（含备选 / 影响）见 `relation-algorithm-decisions.md`。
>
> **回票进度（2026-11-06）**：@riceyu02 与 @pyxz0 均已按建议初值全票确认 7 项（pyxz0 的表态见 #403 最新评论与 `relation-algorithm-decisions.md` §4，其中第 2 / 4 / 7 项附实现前提）；**只剩 zm 未表态**。

- [ ] series 数据结构与字段
- [ ] 打分公式权重初值（标签 / 实体 / 系列各自的权重）
- [ ] `reasons` 字段结构（命中标签 / 实体 / 系列如何表达）
- [ ] 是否引入曝光 / 埋点表（影响 P2）
- [ ] `rating_count` 阈值在关联场景是否沿用 #393 的 50 阈值

## 8. 外部参考

- MAL-Recommender（hybrid 内容/协同、Jaccard、偏好+排除+阈值）：<https://github.com/Joeliazeers/MAL-Recommender>
- asoron/AnimeMangaRecomandadtion（latent + cosine，相似度优先、人气/评分决胜）：<https://github.com/asoron/AnimeMangaRecomandadtion>
- paras603/anime-recommendation（TF-IDF + cosine KNN）：<https://github.com/paras603/anime-recommendation>
- 另：Bangumi 的 subject / 人物 / 制作公司关系模型可作为实体反查的权威参照（不抄其口径，仅借结构）。

## 9. issue 跟踪（均挂 epic #403，2026-11-04 拆分）

| 编号 | 场景 | 优先级 | 归属 | 三人确认项 |
| --- | --- | --- | --- | --- |
| #407 | 作品↔作品 匹配度打分重构（修 findRelated） | P0 | @pyxz0 | 权重初值 / reasons 结构 / rating_count 阈值 |
| #408 | 资讯→作品 渲染（**数据侧导出时 JOIN 成 subject_id** + 服务端 `ArticleDetailAssembler` 解析） | P0 | @riceyu02（客户端随 #425 落地；服务端已实现） | ~~映射表 D1~~ 已撤；只剩数据侧 publisher 切换（zm） |
| #409 | 作品→资讯 反向查询接口（不需映射，直接按 subject_id 匹配） | P0 | @pyxz0（已实现，端点 `GET /api/works/{work_id}/articles`） | 无结构变更；语义开关 `article.related_ids_semantic` 由运维在切流时打开 |
| #410 | 作品→资讯 客户端展示（消费 #409） | P0 | @riceyu02 | — |
| #411 | 系列关联 数据结构 + 反查接口 | P1 | @pyxz0 | series 数据结构 |
| #412 | 实体反查 人物/公司→作品 列表接口 | P1 | @pyxz0 | — |
| #413 | 召回/打分/排序 统一服务 + 曝光埋点 | P2 | @pyxz0 | 是否引入曝光/埋点表 |
| #414 | 资讯↔资讯 共现关联（可选） | P2 | @pyxz0（**已实现**，`GET /api/articles/{id}/related`） | 无结构变更、无迁移 |

> 拆分原则：后端（@pyxz0）负责召回/打分/排序与数据契约，客户端（@riceyu02）只渲染、不自算；涉及数据结构 / 权重 / 埋点的条目需在 #403 决策日志三人确认后再动代码。
>
> **依赖与迁移号协调（2026-11-04 #401 实测后）**：
> - P0 里 **#407 内容 / 标签驱动、不依赖 #240 行为信号，可先推**；**#408/#409 不需要 `work_content_map`**（2026-11-05 生产实测：`article_content_links` 100% 可解析），改由数据侧导出 JOIN + 服务端解析（无新表、无迁移，见 §5.2）。P2 的 #413 与整体推荐（#402）原受 #240 卡，现**开发期可用模拟用户数据先行开发**（生产期接真实信号），见 `algorithm-design.md` §8。
> - #412 依赖 #362 v3 人物前缀键落地（person_id 前缀判强弱关联）+ 列宽 A（保住 >64 超长名键，否则 25 行弱关联被 `cleanStaff` 静默置 null 丢失）。
> - **迁移号（2026-11-05 生产实测更正）**：`V32` 已随 #421（#401 浏览表 `user_work_view`）发版上线（2026-11-04 23:41），**`V31` 从未应用、已被永久跳过**（`application.yml` 未开 `outOfOrder`，默认 false；再放 `V31__*.sql` 会 validate 失败、后端起不来）。故 **#362 前缀迁移 + 列宽 A 改用 `V33`**（31 永久留空，Flyway 允许跳号；`V33` 一个文件同时做 ① 裸数字键 → `bgm:` / `pname:` / `cname:` 改写，② `work_staff.person_id` / `work_characters.person_id` 扩到 128；`cleanStaff` / `cleanCharacters` 的 `normalizeBoundedText(..., 64)` 同步改 128）。**#408 不再需要迁移**（`work_content_map` 已撤，`V34` 空出，让给 #377 的 `article_favorite` 与 #378 的资料字段去排）。写死 V31 或 V34 的旧口径一律以本条为准。
