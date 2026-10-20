# 文档索引

> 本页只做文档导航。**项目目标、技术栈与分工、协作规则、完成标准见仓库根目录 [`README.md`](../README.md)**，这里不再重复。

## 一、当前生效的契约

第一阶段实现以此为准：

- [`docs/stage1-minimal-contract.md`](stage1-minimal-contract.md)：**四个接口的边界与数据格式**——① 网站接入（网站→平台）、② 数据写入（Python→Java）、③ 作品列表、④ 作品详情（Flutter→Java）；另含最小字段集（10 个字段、仅 4 个必填）、唯一标识两层规则、可空规则与创建/更新规则。
- [`docs/openapi.yaml`](openapi.yaml)：上面契约的**机器可读版本**，覆盖接口②③④的请求与响应形状，以及 ③④ 共用的封面代理出口 `GET /api/covers/{work_id}`。接口①不在其中——那是平台只读拉取来源站，来源站接口不由我们定义。

## 二、草案与背景材料

以下为阶段 0 起草的材料，供追溯与评审；**与上一节冲突时以上一节为准**。

- [`docs/data-contract.md`](data-contract.md)：完整数据契约草案（含后续阶段字段），含来源站实测数据事实。
- [`docs/acceptance.md`](acceptance.md)：双端浏览、跨端个人管理与同步可靠性的逐条验收步骤；第 6 节是**阶段 1 实测记录**（2026-10-21，B1–B11 全部通过）。
- [`docs/samples/stage0-sample.json`](samples/stage0-sample.json)：10 组取自真实数据的边界用例样本。

## 三、来源站核查

- [`docs/旧站能力复用清单`](旧站能力复用清单)：现有 Otaku 网站的能力清单，分「可直接复用 / 不需要了 / 不复用」，含站主给定的限流约束、接口未暴露字段清单与待确认问题。

## 四、Flutter 客户端实施文档

- [`docs/dev-setup.md`](dev-setup.md)：Flutter / Android / Windows 桌面开发环境的本机配置记录，含踩坑根因与修复步骤（路径为示例，按自己机器调整）。
- [`docs/flutter-git-branches.md`](flutter-git-branches.md)：客户端侧 Git 分支操作手册——一次性接入、6 条分支的职责与依赖顺序、命名规则、分支从生到死、冲突处理。
- [`docs/flutter-lead-plan.md`](flutter-lead-plan.md)：客户端负责人执行方案——技术选型、目录结构、六周节奏、给 Java 的接口需求单、两端差异清单、验收 checklist。
- [`docs/flutter-scaffold-spec.md`](flutter-scaffold-spec.md)：脚手架开工时确定的实现规格（页面边界、目录、双端差异）。**已按此落地**，保留作追溯，实际行为以代码与 `app-client/README.md` 为准。

## 五、产品规划

- [`docs/otaku-project-plan-v2.md`](otaku-project-plan-v2.md)：产品范围、总体架构、两种同步的边界、阶段划分与验收口径（规划 v0.2 讨论稿）。

## 六、文档维护约定

- 同一主题只在一份文档里写。修订时改对应文件，不新建平行版本。
- 来源站的任何结论必须来自实测或站主明确答复，未验证的一律标注「未验证」。
- 有修改意见请在对应 Issue 提出，涉及其他模块的变更需团队协商。
