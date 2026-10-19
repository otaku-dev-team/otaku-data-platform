# otaku-data-platform

ACGN content aggregation and data synchronization platform

帮助用户发现、查询和管理 ACGN 作品的跨平台平台。由 Flutter 客户端、Java 业务后端和 Python 数据服务三个模块协作完成。

> 当前处于**骨架与规划阶段**。仓库已建立公共目录结构与协作约定，业务功能尚未实现；
> 各模块的具体工程由对应负责人初始化，本仓库不代为决定技术选型。

## 模块与目录

| 目录 | 职责 | 负责人 |
| --- | --- | --- |
| [`app-client/`](app-client/) | Flutter 跨平台客户端，负责界面、交互与 API 接入 | Flutter 负责人 |
| [`backend-java/`](backend-java/) | Java 业务后端，负责业务 API、账号与数据持久化 | Java 负责人 |
| [`sync-python/`](sync-python/) | Python 数据服务，负责来源适配、清洗与同步 | Python 负责人 |
| [`docs/`](docs/) | 项目说明、协作约定与接口文档 | 三人共同维护 |

数据流向：来源数据经 Python 清洗后提交给 Java，Java 保存并提供查询接口，Flutter 客户端只调用 Java 的接口，不直接访问数据源。

## 文档

- [`docs/README.md`](docs/README.md)：项目介绍、分工、第一阶段目标与协作规则
- [`docs/otaku-project-plan-v2.md`](docs/otaku-project-plan-v2.md)：版本规划，含范围、架构、阶段划分与验收标准

接口契约、数据契约与验收清单由三人共同确认后写入 `docs/`，在确认前不视为已生效。

## 协作方式

- **任务与讨论**：使用 GitHub **Issues** 记录开发任务、接口决议与问题反馈。
- **进度跟踪**：使用 GitHub **Projects** 以 `Todo`、`In Progress`、`Done` 跟踪状态。
- **代码提交**：从功能分支发起 **Pull Request**，经评审后合并到 `main`。
- **变更边界**：影响其他模块的接口、数据模型或架构变更，须提前在 Issue 讨论并取得共识。
- **安全约定**：不提交密钥与真实环境配置；AI 生成的代码必须实际检查并运行验证。

## 目录结构

```text
app-client/       Flutter 客户端
backend-java/     Java 业务后端
sync-python/      Python 数据服务
docs/             项目文档
```
