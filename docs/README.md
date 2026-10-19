# 文档索引

> 本页只做文档导航。**项目目标、技术栈与分工、协作规则、完成标准见仓库根目录 [`README.md`](../README.md)**，这里不再重复。

## 一、当前生效的契约

第一阶段实现以此为准：

- [`docs/stage1-minimal-contract.md`](stage1-minimal-contract.md)：第一阶段最小字段集（10 个字段、仅 4 个必填）、作品唯一标识两层规则、可空规则，以及 Python→Java 与 Flutter→Java 两组最小接口约定。

## 二、草案与背景材料

以下为阶段 0 起草的草案与实测材料，供追溯与评审；**与上一节冲突时以上一节为准**。

- [`docs/data-contract.md`](data-contract.md)：作品身份、来源映射、字段与更新规则，含来源站实测数据事实。
- [`docs/openapi.yaml`](openapi.yaml)：接口契约草案。`/internal/*` 为 Python 同步作业专用，`/api/*` 为 Java 提供给客户端的接口。URL、DTO 与代码组织由 Java 负责人定。
- [`docs/acceptance.md`](acceptance.md)：双端浏览、跨端个人管理与同步可靠性的逐条验收步骤。
- [`docs/samples/stage0-sample.json`](samples/stage0-sample.json)：10 组取自真实数据的边界用例样本。

## 三、来源站核查

- [`docs/旧站能力复用清单`](旧站能力复用清单)：现有 Otaku 网站的能力清单，分「可直接复用 / 不需要了 / 不复用」，含站主给定的限流约束、接口未暴露字段清单与待确认问题。

## 四、产品规划

- [`docs/otaku-project-plan-v2.md`](otaku-project-plan-v2.md)：产品范围、总体架构、两种同步的边界、阶段划分与验收口径（规划 v0.2 讨论稿）。

## 五、文档维护约定

- 同一主题只在一份文档里写。修订时改对应文件，不新建平行版本。
- 来源站的任何结论必须来自实测或站主明确答复，未验证的一律标注「未验证」。
- 有修改意见请在对应 Issue 提出，涉及其他模块的变更需团队协商。
