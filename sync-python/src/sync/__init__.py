"""otaku-data-platform 的 Python 数据同步模块。

职责边界（见 ../../docs/data-contract.md）：
- 从约定来源读取作品数据，完成校验、清洗、字段转换
- 通过内部导入 API 提交给 Java 后端，**不直接写业务数据库**
- 具备有限重试、失败记录和安全重跑能力

当前状态：骨架与清洗逻辑已实现，可脱离 Java 独立运行（--dry-run）。
内部导入接口的具体行为待 openapi.yaml 评审通过后按最终契约调整。
"""

__all__ = ["__version__"]

__version__ = "0.1.0"
