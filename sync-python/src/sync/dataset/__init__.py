"""同步数据集：把任意客户源库翻译成我们自己的标准格式。

为什么单独成包而不是塞进 `sources/`：`sources/` 是**读接口**的适配器（REST / 档案），
这里是**读数据库**的适配器，且多了一层「契约收敛」——源有 90 个字段，
契约只收 9 个，这个收敛动作不属于任何单一 source。

对外只暴露四件事：加载映射、导出、版本校验、读元信息。
"""

from .exporter import (
    BreakingSchemaChange,
    ExportReport,
    assert_compatible,
    export_dataset,
    read_meta,
)
from .mapping import DatasetMapping, MappingError, probe_sqlite, resolve
from .schema import DATASET_TABLES, DATASET_VERSION, EXPORTER_VERSION

__all__ = [
    "BreakingSchemaChange",
    "DATASET_TABLES",
    "DATASET_VERSION",
    "DatasetMapping",
    "EXPORTER_VERSION",
    "ExportReport",
    "MappingError",
    "assert_compatible",
    "export_dataset",
    "probe_sqlite",
    "read_meta",
    "resolve",
]
