# 文档索引

> 本页只做文档导航。**项目目标、技术栈与分工、协作规则、完成标准见仓库根目录 [`README.md`](../README.md)**，这里不再重复。

## 一、当前生效的契约

第一阶段实现以此为准：

- [`docs/stage1-minimal-contract.md`](stage1-minimal-contract.md)：**四个接口的边界与数据格式**——① 网站接入（网站→平台）、② 数据写入（Python→Java）、③ 作品列表、④ 作品详情（Flutter→Java）；另含最小字段集（10 个字段、仅 4 个必填）、唯一标识两层规则、可空规则与创建/更新规则。
- [`docs/openapi.yaml`](openapi.yaml)：上面契约的**机器可读版本**，覆盖接口②③④的请求与响应形状，以及 ③④ 共用的封面代理出口 `GET /api/covers/{work_id}`。接口①不在其中——那是平台只读拉取来源站，来源站接口不由我们定义。

## 一之二、项目总纲与授权

- [`docs/project-charter.md`](project-charter.md)：**项目总纲**——总目标 G1–G3、六条工作流 W1–W6、两个探索项、授权与自治规则、必须回来确认的红线、验收与信任机制。**先读这一份再看其他。**
- [`docs/collaboration-protocol.md`](collaboration-protocol.md)：**并行开发时的阻塞处理**——三类阻塞各怎么应对、「确认默认同意、沉默不阻塞」（PR 是通知不是闸门）、冲突归作者解。**开工前读一遍，省掉等点头的时间。**
- [`docs/ROADMAP.md`](ROADMAP.md)：唯一看板，含阶段总览（§6）与工作流看板（§8）。
- [`docs/product-positioning.md`](product-positioning.md)：**上位依据**（2026-10-24 起，定位 > 契约 > 其他文档）——商业模式、身份归属、六条边界、运营形态三态（附录 A：站点生命周期与关停预案）。技术判断有分歧时以它为准。
- [`docs/merge-queue.md`](merge-queue.md)：合并队列与合并后动作清单——栈关系、四批合并顺序、合并后要关 / rebase 的分支、三个已知坑。合并期间以这份为准。

## 二、草案与背景材料

以下为阶段 0 起草的材料，供追溯与评审；**与上一节冲突时以上一节为准**。

- [`docs/data-contract.md`](data-contract.md)：完整数据契约草案（含后续阶段字段），含来源站实测数据事实。
- [`docs/stage2-account-collection-contract.md`](stage2-account-collection-contract.md)：**第二阶段（账号与收藏）契约**，对应验收 C1–C11。含 8 个接口、新增错误码与 C1–C11 的逐条映射。**已实现并双端验收**（2026-10-21，见 [`stage2-acceptance.md`](stage2-acceptance.md)），接口已落 `openapi.yaml`。
- [`docs/w1.3-notification-proposal.md`](w1.3-notification-proposal.md)：**W1.3 通知触达方案草案**。建议拆成「本地提醒（纯客户端，可立即做）」与「服务端推送（需新增设备令牌端点，属红线）」两半；含端点、字段、表结构与事件载荷的提议。**尚未生效**，需三人确认。
- [`docs/acceptance.md`](acceptance.md)：双端浏览、跨端个人管理与同步可靠性的逐条验收步骤；第 6 节是**阶段 1 实测记录**（2026-10-21，B1–B11 全部通过）。
- [`docs/stage2-acceptance.md`](stage2-acceptance.md)：阶段 2 双端实测记录（2026-10-21，Windows 桌面 + Android），含 §8 用例与 C1–C11 的覆盖对照。
- [`docs/stage3-performance-baseline.md`](stage3-performance-baseline.md)：**万级列表的滚动基线**（2026-10-21 实测）。含帧耗时、内存曲线、分页请求数与两个真实瓶颈（封面重复回源、封面按原图解码），以及复现脚本的用法。
- [`docs/stage3-reliability-record.md`](stage3-reliability-record.md)：阶段 3 可靠性实测记录。
- [`docs/identity-auth-endpoint-playbook.md`](identity-auth-endpoint-playbook.md)：站点授权端点预案与联调手册——标准 OAuth 授权码四端点、三点安全调整、self-revoke 三态、联调配置（凭据存环境变量，不入库）。
- 平台侧令牌交换代理联调契约草案（PR #147，待三人确认）：用户表加列、账号映射与收藏迁移设计。
- [`docs/site-owner-console-proposal.md`](site-owner-console-proposal.md)：**站主运营后台立项草案**（#144）——范围、权限模型、「禁用 ≠ 封网站账号」的边界，以及六项拍板结论；实现已落地，见下一行。
- [`docs/site-owner-console.md`](site-owner-console.md)：**站主后台使用说明（首版）**——站主能做什么/不能做什么、数据隔离怎么保证、平台运维怎么开通站主、禁用到底禁了什么、已知未做。
- [`docs/data-completeness-plan.md`](data-completeness-plan.md)：数据缺口体检与补齐路径（封面 / 评分 / 简介三线，结论：封面走 C+A）。
- [`docs/db-intake-dataset.md`](db-intake-dataset.md)：**数据库直读方案**——库与接口是**两个正交维度**（交付形态 ≠ 数据入口，私有化不等于能给库）；SQLite 无授权体系故只能物理隔离（派生库）、结构耦合压进声明式映射 + 三档缺列处置（主键消失即停机）、参照 Airbyte/dlt/dbt 却不引入的理由，以及 `sync-dataset` 导出 → 提交两段的落地状态与待办。
- [`docs/person-id-unification.md`](person-id-unification.md)：**人物 id 口径统一**——原先 `people.source_id`（网站自增）与 `person_ref`（Bangumi 人物 id）是两套 id 空间、4,115 个数值撞车；**已定案**改前缀键（`bgm:` 强关联 / `pname:` `cname:` 弱关联），人物与公司端点形状照首站（`/cast/{id}`、`/studios/{name}`）。含证据链、三档范围与已定案的三条。
- [`docs/client-enhancement-plan.md`](client-enhancement-plan.md)：客户端体验增强计划（边界状态、发现体验等轨道）。
- [`docs/generalization-proposal.md`](generalization-proposal.md)：**未来目标**（当前不实施）——通用化方向 `custom_fields` + `display_template`；新决策须兼容它。
- [`docs/ironlaw-positioning-analysis.md`](ironlaw-positioning-analysis.md)：铁律与定位冲突的历史分析（已被 2026-10-24 定位修正取代，留作追溯）。
- [`docs/w1.3-notification-proposal.md`](w1.3-notification-proposal.md)：**W1.3 通知触达方案草案**。拆「本地提醒（纯客户端）」与「服务端推送（需新增设备令牌端点，属红线）」两半；本地提醒那半已实现进 main，服务端推送待确认。
- [`docs/w1-real-data-probe.md`](w1-real-data-probe.md)：**W1.4 真实数据联调记录**——本机起 MySQL/后端/客户端的复现命令、契约行为实测（含未知标签 200+空）、边界数据分布（无评分 63.8% / 无封面 97.3% / 标题最长 146 字符）、六条走查清单（其中四条已自动化，附 fixture 重新生成的方法），以及待人工走查的部分。
- [`docs/site-branding.md`](site-branding.md)：**站点品牌配置**——应用名 / 归属方 / 包名怎么按站点区分（定位 §7.2 要求 2）。分「运行时可定」与「只能构建期定」两类，附私有化交付 checklist。
- [`docs/w1-login-dual-entry.md`](w1-login-dual-entry.md)：**登录页双入口方案**（回应 #147 待确认第 3 项）。来源站账号走系统浏览器授权为主入口、平台账号表单退为次级；含 state 落盘、错误分支、401 静默重走、桌面端暂不呈现，以及给后端的三个输入。**尚未生效**，需三人确认。
- [`docs/samples/stage0-sample.json`](samples/stage0-sample.json)：10 组取自真实数据的边界用例样本。

## 三、来源站核查

- [`docs/旧站能力复用清单`](旧站能力复用清单)：现有 Otaku 网站的能力清单，分「可直接复用 / 不需要了 / 不复用」，含站主给定的限流约束、接口未暴露字段清单与待确认问题。
- [`docs/站点能力差距清单.md`](站点能力差距清单.md)：站点能力差距与探针结论（含富字段为何 JSON 不出口、P3 现实路径）。
- [`docs/首站资产复用评估.md`](首站资产复用评估.md)：**从源码清点的资产复用状态**（上面两份是从外面探测，这份是读源码）——六类资产的复用率：数据表映射 100%、几何常量 100%、颜色令牌 47%、设计令牌全量 16%、知识词表与收录口径 0；含「该做两件、明确不做三件」的结论与复现命令。
- [`docs/首站收录口径与资讯过滤.md`](首站收录口径与资讯过滤.md)：**口径存档（防分叉锚点）**——游戏收录 v3 的五类优先级与词表原文、非游戏条目的类型判定、资讯三条过滤规则（自营按源分表 / 周报即拒 / 联名周边）与三个设计选择，附改动联动点与核对命令。**存的是首站的口径，我们只跟取数不复刻。**

## 四、Flutter 客户端实施文档

- [`docs/dev-setup.md`](dev-setup.md)：Flutter / Android / Windows 桌面开发环境的本机配置记录，含踩坑根因与修复步骤（路径为示例，按自己机器调整）。
- [`docs/flutter-git-branches.md`](flutter-git-branches.md)：客户端侧 Git 分支操作手册——一次性接入、6 条分支的职责与依赖顺序、命名规则、分支从生到死、冲突处理。
- [`docs/flutter-lead-plan.md`](flutter-lead-plan.md)：客户端负责人执行方案——技术选型、目录结构、六周节奏、给 Java 的接口需求单、两端差异清单、验收 checklist。
- [`docs/flutter-scaffold-spec.md`](flutter-scaffold-spec.md)：脚手架开工时确定的实现规格（页面边界、目录、双端差异）。**已按此落地**，保留作追溯，实际行为以代码与 `app-client/README.md` 为准。
- [`docs/client-capability-list.md`](client-capability-list.md)：**客户端能力承载清单**——哪些能力 App 原生做、哪些跳来源站，按站点维护，随版本更新。回答客户那句「什么都跳回网站要你们干什么」。
- [`docs/design-style.md`](design-style.md)：**设计风格定稿**——主色 `#66CCFF` 的三个角色（做底 / 做字 / 做线）与实测对比度、色板分层、类型色四色相、卡片靠描边不靠阴影、间距字号圆角令牌、深色与系统取色的推导规则、组件层约定，以及五处明确不统一的地方。

## 五、产品规划

- [`docs/otaku-project-plan-v2.md`](otaku-project-plan-v2.md)：产品范围、总体架构、两种同步的边界、阶段划分与验收口径（规划 v0.2 讨论稿）。
- [`docs/site-feature-adaptation-plan.md`](site-feature-adaptation-plan.md)：站点特色功能适配方案——L1/L2/L3 分级、适配包形态；附录 B 是齐平验收标准（9 成，开发期非闸门），附录 C 是排除清单复审记录。
- [`docs/open-decisions.md`](open-decisions.md)：待决策清单（A 商务 / B 承诺边界 / C 技术契约 / D 数据事实），文末附已定事项备查表。

## 六、对外口径与运维

- [`docs/how-we-serve-sites.md`](how-we-serve-sites.md)：对站点方说明"我们做什么、不做什么、怎么计费"的对外口径。
- [`docs/deploy-production.md`](deploy-production.md)：生产部署步骤与拓扑（MySQL + 后端容器、封面回源白名单）。
- [`docs/deployment-schedule.md`](deployment-schedule.md)：**接单后 3 天部署**的排期——接单前必建的 P1–P9、四条独立并行流、逐日执行窗口与当前卡点。
- [`docs/bangumi-archive-handover.md`](bangumi-archive-handover.md)：Bangumi 档案灌库说明（55.6 万条来源与管线）。

## 七、文档维护约定

- 同一主题只在一份文档里写。修订时改对应文件，不新建平行版本。
- 来源站的任何结论必须来自实测或站主明确答复，未验证的一律标注「未验证」。
- 有修改意见请在对应 Issue 提出，涉及其他模块的变更需团队协商。
