# 适配器模板 + 站点配置 Spec（理论草案）

> **状态标注**：本文档为「理论中 / 未实现 / 未经客户端第二实例验证」。
> 用途：价值拓展叙事的轻量 spec，**不进入 A 桶工程排期**，不承诺交付。所有"通用/适配"表述均基于 **Otaku 单实例**推导，待第二实例（客户端）验证。
> 归属：B 桶（技术侧产出，不占 A 桶排期）。同层文档见 `docs/site-feature-adaptation-plan.md`；源无关内核的**真实部分**见 §2（已落地），本文其余为理论扩展。

## 1. 定位与边界

- 本 spec 描述"若要将另一个站点接入本系统"所需的**适配器契约 + 站点配置项**。
- **已真实存在**的是数据/接入层的源无关内核（§2）；**未实现**的是"把它变成可交付给其他站主的客户端方案"——本文档即描述后者该长什么样。
- **红线**：运行期"一个 App 选站点"禁止；每站一个独立品牌客户端（构建期烘焙）。

## 2. 已真实的部分（架构背书，非理论）

以下为已落地、可对外诚实引用的资产（据架构探查）：

- **Source 协议**（sync-python）：抽象数据源接口，当前实现 `OtakuSiteSource` / `BangumiArchiveSource` / `VndbSource`。
- **源无关数据模型**：实体以通用键 `(source, source_id)` 归一，不绑定单一站点 id。
- **运行期配置表** `app_config`：承载每源/每站配置。
- **治理脚本** `check-site-isolation.py`：强制站点隔离。
- **已接入第二数据源（VNDB）实测通过**（⚠️ 是否进入 live pipeline 待 G2 证据整理确认）。

## 3. 通用数据模型字段集（基于 Otaku 单例推导，待验证）

核心实体（来自现有 schema，键统一为 `(source, source_id)`）：

| 实体 | 关键字段（通用键 + 领域字段） | 说明 |
|---|---|---|
| `contents` | `source`, `source_id`, `title`, `cover_url`, `summary`, `meta` | 作品；`cover_url` 自持回填，非站点 id 派生 |
| `entities` | `source`, `source_id`, `type(person/company)`, `name` | 人物/公司；首站 `bangumi_person_id` 为回溯用，非通用键 |
| `content_cast` | `content_source`, `content_source_id`, `person_source`, `person_source_id`, `role` | 出演；person 侧已 100% 有 id |
| `content_credits` | `content_source`, `content_source_id`, `person_source`, `person_source_id`, `credit_type` | 主创；约 17.4% 无 id，归一依赖名字匹配 |
| `content_studios` | `content_source`, `content_source_id`, `studio_name` | 制作公司；去重公司名约 1,604 |

> ⚠️ 上述字段集从 Otaku/Bangumi 单例投影，**未经第二站点（不同类型）验证**；跨域（如博客/电商）字段必然差异，本文档不覆盖。

## 4. 适配器输入输出契约（理论）

一个 `Source` 适配器需实现：

- **入参**：站点配置 `SiteConfig`（见 §5）+ 增量游标。
- **出参**：规范化的 `contents` / `entities` / `content_cast` / `content_credits` / `content_studios` 行，全部带 `(source, source_id)` 键。
- **约束**：适配器只负责"把站点数据翻译成规范模型"，不碰客户端品牌、不碰站点运营内容（职责边界）。
- **隔离**：每个源产出经 `check-site-isolation.py` 校验，禁止跨源 id 串扰。

## 5. 站点配置项（sites/\<site\>/site.conf，理论）

| 配置项 | 含义 | 备注 |
|---|---|---|
| `app_name` | 应用显示名（如 Otaku） | 构建期烘焙 |
| `icon` | 应用图标 | 按站提供 |
| `package_id` | 应用包名（如 com.otaku.app） | 每站独立 |
| `brand_color` | 品牌色（如 #66CCFF） | 按站参数，非首站抄死 |
| `sources[]` | 该站接入的数据源列表 | 引用 §4 适配器 |

> ⚠️ 当前 `build_site.sh` 的品牌注入管道已断（2026-10-28 起客户端不再读取），`site.conf` 部分未接线——这是 G3 换肤 demo 要修复的（演示件，不运营第二站）。

## 6. 按站交付路径（build-time 烘焙，理论）

1. 复制 `sites/<site>/site.conf` 填目标站品牌/数据源。
2. 接入对应 `Source` 适配器（已有则复用，无则按 §4 新写）。
3. 构建期烘焙出独立品牌客户端（应用名/图标/包名/品牌色独立）。
4. **运行期不提供站点切换**；每站独立分发。

## 7. 诚实分级（对外必读）

| 项 | 对外状态 |
|---|---|
| 源无关内核 + 可插拔源 | **已落地 / 已跨 2 源（Bangumi+VNDB）** |
| 换肤 demo（同内核→不同品牌壳） | **机制已演示（G3，非真实多站客户）** |
| 适配器模板 / 站点配置 / 跨域多站交付 | **理论中 / 未实现 / 未经客户端第二实例验证** |

---
*本文件为理论草案，配合 `topics/positioning.md` 的「工程范围分层」使用；任何对外引用须遵守 G5 诚实分级标注。*
