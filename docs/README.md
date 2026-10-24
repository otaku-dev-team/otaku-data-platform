# 文档索引

> 本页只做文档导航。**项目目标、技术栈与分工、协作规则、完成标准见仓库根目录 [`README.md`](../README.md)**，这里不再重复。

## 一、当前生效的契约

第一阶段实现以此为准：

- [`docs/stage1-minimal-contract.md`](stage1-minimal-contract.md)：**四个接口的边界与数据格式**——① 网站接入（网站→平台）、② 数据写入（Python→Java）、③ 作品列表、④ 作品详情（Flutter→Java）；另含最小字段集（10 个字段、仅 4 个必填）、唯一标识两层规则、可空规则与创建/更新规则。
- [`docs/openapi.yaml`](openapi.yaml)：上面契约的**机器可读版本**，覆盖接口②③④的请求与响应形状，以及 ③④ 共用的封面代理出口 `GET /api/covers/{work_id}`。接口①不在其中——那是平台只读拉取来源站，来源站接口不由我们定义。

## 一之二、项目总纲与授权

- [`docs/project-charter.md`](project-charter.md)：**项目总纲**——总目标 G1–G3、六条工作流 W1–W6、两个探索项、授权与自治规则、必须回来确认的红线、验收与信任机制。**先读这一份再看其他。**
- [`docs/ROADMAP.md`](ROADMAP.md)：唯一看板，含阶段总览（§6）与工作流看板（§8）。
- [`docs/product-positioning.md`](product-positioning.md)：**上位依据**（2026-10-24 起，定位 > 契约 > 其他文档）——商业模式、身份归属、六条边界、运营形态三态（附录 A：站点生命周期与关停预案）。技术判断有分歧时以它为准。
- [`docs/merge-queue.md`](merge-queue.md)：合并队列与合并后动作清单——栈关系、四批合并顺序、合并后要关 / rebase 的分支、三个已知坑。合并期间以这份为准。

## 二、草案与背景材料

以下为阶段 0 起草的材料，供追溯与评审；**与上一节冲突时以上一节为准**。

- [`docs/data-contract.md`](data-contract.md)：完整数据契约草案（含后续阶段字段），含来源站实测数据事实。
- [`docs/stage2-account-collection-contract.md`](stage2-account-collection-contract.md)：**第二阶段（账号与收藏）契约**，对应验收 C1–C11。含 8 个接口、新增错误码与 C1–C11 的逐条映射。**已实现并双端验收**（2026-10-21，见 [`stage2-acceptance.md`](stage2-acceptance.md)），接口已落 `openapi.yaml`。
- [`docs/acceptance.md`](acceptance.md)：双端浏览、跨端个人管理与同步可靠性的逐条验收步骤；第 6 节是**阶段 1 实测记录**（2026-10-21，B1–B11 全部通过）。
- [`docs/stage2-acceptance.md`](stage2-acceptance.md)：阶段 2 双端实测记录（2026-10-21，Windows 桌面 + Android），含 §8 用例与 C1–C11 的覆盖对照。
- [`docs/stage3-performance-baseline.md`](stage3-performance-baseline.md)：**万级列表的滚动基线**（2026-10-21 实测）。含帧耗时、内存曲线、分页请求数与两个真实瓶颈（封面重复回源、封面按原图解码），以及复现脚本的用法。
- [`docs/stage3-reliability-record.md`](stage3-reliability-record.md)：阶段 3 可靠性实测记录。
- [`docs/identity-auth-endpoint-playbook.md`](identity-auth-endpoint-playbook.md)：站点授权端点预案与联调手册——标准 OAuth 授权码四端点、三点安全调整、self-revoke 三态、联调配置（凭据存环境变量，不入库）。
- 平台侧令牌交换代理联调契约草案（PR #147，待三人确认）：用户表加列、账号映射与收藏迁移设计。
- [`docs/data-completeness-plan.md`](data-completeness-plan.md)：数据缺口体检与补齐路径（封面 / 评分 / 简介三线，结论：封面走 C+A）。
- [`docs/client-enhancement-plan.md`](client-enhancement-plan.md)：客户端体验增强计划（边界状态、发现体验等轨道）。
- [`docs/generalization-proposal.md`](generalization-proposal.md)：**未来目标**（当前不实施）——通用化方向 `custom_fields` + `display_template`；新决策须兼容它。
- [`docs/ironlaw-positioning-analysis.md`](ironlaw-positioning-analysis.md)：铁律与定位冲突的历史分析（已被 2026-10-24 定位修正取代，留作追溯）。
- [`docs/samples/stage0-sample.json`](samples/stage0-sample.json)：10 组取自真实数据的边界用例样本。

## 三、来源站核查

- [`docs/旧站能力复用清单`](旧站能力复用清单)：现有 Otaku 网站的能力清单，分「可直接复用 / 不需要了 / 不复用」，含站主给定的限流约束、接口未暴露字段清单与待确认问题。
- [`docs/站点能力差距清单.md`](站点能力差距清单.md)：站点能力差距与探针结论（含富字段为何 JSON 不出口、P3 现实路径）。

## 四、Flutter 客户端实施文档

- [`docs/dev-setup.md`](dev-setup.md)：Flutter / Android / Windows 桌面开发环境的本机配置记录，含踩坑根因与修复步骤（路径为示例，按自己机器调整）。
- [`docs/flutter-git-branches.md`](flutter-git-branches.md)：客户端侧 Git 分支操作手册——一次性接入、6 条分支的职责与依赖顺序、命名规则、分支从生到死、冲突处理。
- [`docs/flutter-lead-plan.md`](flutter-lead-plan.md)：客户端负责人执行方案——技术选型、目录结构、六周节奏、给 Java 的接口需求单、两端差异清单、验收 checklist。
- [`docs/flutter-scaffold-spec.md`](flutter-scaffold-spec.md)：脚手架开工时确定的实现规格（页面边界、目录、双端差异）。**已按此落地**，保留作追溯，实际行为以代码与 `app-client/README.md` 为准。
- [`docs/client-capability-list.md`](client-capability-list.md)：**客户端能力承载清单**——哪些能力 App 原生做、哪些跳来源站，按站点维护，随版本更新。回答客户那句「什么都跳回网站要你们干什么」。

## 五、产品规划

- [`docs/otaku-project-plan-v2.md`](otaku-project-plan-v2.md)：产品范围、总体架构、两种同步的边界、阶段划分与验收口径（规划 v0.2 讨论稿）。
- [`docs/site-feature-adaptation-plan.md`](site-feature-adaptation-plan.md)：站点特色功能适配方案——L1/L2/L3 分级、适配包形态；附录 B 是齐平验收标准（9 成，开发期非闸门），附录 C 是排除清单复审记录。
- [`docs/open-decisions.md`](open-decisions.md)：待决策清单（A 商务 / B 承诺边界 / C 技术契约 / D 数据事实），文末附已定事项备查表。

## 六、对外口径与运维

- [`docs/how-we-serve-sites.md`](how-we-serve-sites.md)：对站点方说明"我们做什么、不做什么、怎么计费"的对外口径。
- [`docs/deploy-production.md`](deploy-production.md)：生产部署步骤与拓扑（MySQL + 后端容器、封面回源白名单）。
- [`docs/bangumi-archive-handover.md`](bangumi-archive-handover.md)：Bangumi 档案灌库说明（55.6 万条来源与管线）。

## 七、文档维护约定

- 同一主题只在一份文档里写。修订时改对应文件，不新建平行版本。
- 来源站的任何结论必须来自实测或站主明确答复，未验证的一律标注「未验证」。
- 有修改意见请在对应 Issue 提出，涉及其他模块的变更需团队协商。
