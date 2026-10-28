"""声明式映射：把「某个客户源库」翻译成「标准数据集」。

## 耦合怎么解

结构强耦合有两种死法，分开治：

1. **列不存在了**（客户删列/改名）—— 旧代码 `SELECT col` 直接抛异常，整批导入失败。
   这里改成**逐字段降级**：探测真实列，缺的字段置 null 并记进报告，
   其余字段照常导出。降到 `required` 字段都不在时才让该表整体跳过。
2. **表名/取值变了**（`type` 从"动画"改成"anime"、`week_tags` 从斜杠串改成 JSON）
   —— 值域漂移不会抛异常，只会**静默写坏数据**，这比崩更危险。
   这里用 `enum_map` + `min/max` + 导出后统计（空值率、未知枚举、越界）把
   静默变成可见：数据照进，报告里指出「这个字段 37% 不认识」。

映射本身是**配置而非代码**（`mappings/*.json`），接新客户只加一个文件。
每个映射带结构指纹（表+列+类型的哈希），指纹变了不阻断导出，但会在报告里
写明「相较上次多了/少了哪些列」——让运维在数据写歪之前看见。
"""

from __future__ import annotations

import hashlib
import json
import sqlite3
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .schema import (
    DATASET_VERSION,
    PUBLIC_SOURCE_TABLES,
    is_forbidden_source_table,
)

#: 字段类型。全部落到 SQLite 的 TEXT/INTEGER/REAL，转换在导出时做，
#: 不做隐式猜测——猜错比留空更糟。
FIELD_TYPES = frozenset({
    "str", "text", "int", "float", "bool",
    "json_list", "json_obj", "datetime", "enum", "bracket_list",
})
#: ``bracket_list``：源列是 ``{\n[别名]\n}`` 这类括号包裹的多行文本（或只含一个
#: 这种文本的 JSON 数组）时，拆成字符串数组。解析见 ``exporter._parse_bracket_list``。

#: 缺列时的处置，三档。这套分级不是自创，是 Airbyte schema change management
#: 的工业共识（新增列自动加 / 删列保留 / 类型变更记错 / 主键或 cursor 消失暂停）：
#:
#: - ``degrade``：置 null 继续导出。用于富字段、可选字段——缺了就少一块内容，
#:   不影响这条作品仍然可用。
#: - ``reject``：该行整条拒绝。用于「有了才成立」的字段，例如标题。
#: - ``break``：**整批停止，等人工处理**。用于主键与增量游标。
#:
#: 为什么必须有 ``break``：主键列被改名/删除时，如果按 degrade 处理，
#: 我们照样能导出一张「能写入、但每条都指向错主键」的表，导入器会把它当成
#: 全量新增，静默产生几十万条重复脏数据。崩掉比这个结果好得多。
ON_MISSING = frozenset({"degrade", "reject", "break"})

_IDENT_OK = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")


class MappingError(ValueError):
    """映射配置本身有问题（不是数据问题）。"""


def _require_ident(name: str, what: str) -> str:
    """校验标识符，防止映射文件里的表名/列名被拼进 SQL 时逃逸。

    映射是我们自己的资产，但「自己的资产」不等于「不会有人手滑」，
    拼接前统一过一遍比事后审计便宜。
    """
    if not name or not set(name) <= _IDENT_OK:
        raise MappingError(f"{what} 含非法字符: {name!r}")
    return name


@dataclass(frozen=True)
class FieldSpec:
    """一个标准字段的来源与转换规则。"""

    target: str
    column: str | None = None
    type: str = "str"
    required: bool = False
    on_missing: str = "degrade"
    enum_map: dict[str, str] | None = None
    default: Any = None
    minimum: float | None = None
    maximum: float | None = None
    scale: str | None = None
    const: Any = None

    @classmethod
    def parse(cls, raw: dict[str, Any]) -> "FieldSpec":
        target = raw.get("target")
        if not target:
            raise MappingError("字段缺少 target")
        _require_ident(str(target), "target")

        ftype = raw.get("type", "str")
        if ftype not in FIELD_TYPES:
            raise MappingError(f"{target}: 未知字段类型 {ftype!r}")

        on_missing = raw.get("on_missing", "degrade")
        if on_missing not in ON_MISSING:
            raise MappingError(f"{target}: 未知 on_missing {on_missing!r}")

        column = raw.get("column")
        if column is not None:
            _require_ident(str(column), f"字段 {target} 的 column")
        if column is None and raw.get("const") is None:
            raise MappingError(f"{target}: 必须给 column 或 const")

        enum_map = raw.get("enum_map")
        if ftype == "enum" and not enum_map:
            raise MappingError(f"{target}: 类型 enum 必须给 enum_map")
        if enum_map is not None and not isinstance(enum_map, dict):
            raise MappingError(f"{target}: enum_map 必须是对象")

        return cls(
            target=target,
            column=column,
            type=ftype,
            required=bool(raw.get("required", False)),
            on_missing=on_missing,
            enum_map=enum_map,
            default=raw.get("default"),
            minimum=raw.get("min"),
            maximum=raw.get("max"),
            scale=raw.get("scale"),
            const=raw.get("const"),
        )


@dataclass(frozen=True)
class TableSpec:
    """一张标准表怎么从源库取。"""

    target: str
    mode: str = "table"          # table = 逐列映射；query = 一条 SQL 直接产出标准列
    source: str | None = None
    key: str | None = None
    filter: str | None = None    # 追加 WHERE 条件（如 is_published = 1）
    sql: str | None = None
    required_sources: tuple[str, ...] = ()
    fields: tuple[FieldSpec, ...] = ()

    @classmethod
    def parse(cls, raw: dict[str, Any]) -> "TableSpec":
        target = raw.get("target")
        if not target:
            raise MappingError("表缺少 target")
        _require_ident(str(target), "target")

        mode = raw.get("mode", "table")
        if mode not in ("table", "query"):
            raise MappingError(f"{target}: 未知 mode {mode!r}")

        source = raw.get("source")
        if mode == "table":
            if not source:
                raise MappingError(f"{target}: table 模式必须给 source")
            _require_ident(str(source), f"表 {target} 的 source")
            if is_forbidden_source_table(str(source)):
                raise MappingError(
                    f"{target}: 源表 {source!r} 属于禁区（用户/凭据/收藏/日志类），拒绝导出"
                )
            if str(source) not in PUBLIC_SOURCE_TABLES:
                raise MappingError(
                    f"{target}: 源表 {source!r} 不在公开内容白名单内，"
                    f"如确需新增请先更新 schema.PUBLIC_SOURCE_TABLES 并说明理由"
                )
            fields = tuple(FieldSpec.parse(f) for f in raw.get("fields") or [])
            if not fields:
                raise MappingError(f"{target}: table 模式必须给 fields")
            targets = [f.target for f in fields]
            dup = {t for t in targets if targets.count(t) > 1}
            if dup:
                raise MappingError(f"{target}: 字段重复 {sorted(dup)}")
        else:
            if not raw.get("sql"):
                raise MappingError(f"{target}: query 模式必须给 sql")
            fields = ()
            source = None

        req = raw.get("required_sources") or ()
        for name in req:
            _require_ident(str(name), f"表 {target} 的 required_sources")
            if str(name) not in PUBLIC_SOURCE_TABLES:
                raise MappingError(
                    f"{target}: required_sources 里的 {name!r} 不在公开内容白名单内"
                )

        key = raw.get("key")
        if key is not None:
            _require_ident(str(key), f"表 {target} 的 key")

        return cls(
            target=target,
            mode=mode,
            source=str(source) if source else None,
            key=str(key) if key else None,
            filter=raw.get("filter"),
            sql=raw.get("sql"),
            required_sources=tuple(str(x) for x in req),
            fields=fields,
        )


@dataclass(frozen=True)
class DatasetMapping:
    """一个客户的完整映射。"""

    dataset_version: str
    source_id: str
    tables: tuple[TableSpec, ...]
    path: Path | None = None

    @classmethod
    def load(cls, path: str | Path) -> "DatasetMapping":
        p = Path(path)
        try:
            raw = json.loads(p.read_text(encoding="utf-8"))
        except FileNotFoundError as exc:
            raise MappingError(f"映射文件不存在: {p}") from exc
        except json.JSONDecodeError as exc:
            raise MappingError(f"映射文件不是合法 JSON: {p} -> {exc}") from exc

        version = str(raw.get("dataset_version", ""))
        if version != DATASET_VERSION:
            raise MappingError(
                f"映射的 dataset_version={version!r}，本导出器只支持 {DATASET_VERSION!r}"
            )

        source_id = raw.get("source_id")
        if not source_id:
            raise MappingError("映射缺少 source_id")

        raw_tables = raw.get("tables")
        if not raw_tables:
            raise MappingError("映射缺少 tables")

        tables = tuple(TableSpec.parse(t) for t in raw_tables)
        targets = [t.target for t in tables]
        dup = {t for t in targets if targets.count(t) > 1}
        if dup:
            raise MappingError(f"目标表重复: {sorted(dup)}")

        return cls(
            dataset_version=version,
            source_id=str(source_id),
            tables=tables,
            path=p,
        )


# ---------------------------------------------------------------- 结构探测


def probe_sqlite(conn: sqlite3.Connection) -> dict[str, dict[str, str]]:
    """读取源库真实结构：{表名: {列名: 声明类型}}。

    只读 `sqlite_master` + `PRAGMA table_info`，不碰任何数据行。
    """
    out: dict[str, dict[str, str]] = {}
    rows = conn.execute(
        "select name from sqlite_master where type='table' order by name"
    ).fetchall()
    for (name,) in rows:
        if name.startswith("sqlite_"):
            continue
        info = conn.execute(f'PRAGMA table_info("{name}")').fetchall()
        out[str(name)] = {str(r[1]): str(r[2] or "") for r in info}
    return out


def fingerprint(probe: dict[str, dict[str, str]]) -> str:
    """结构指纹：表名 + 列名 + 声明类型的稳定哈希。

    只取公开表，避免因为客户新增一张日志表就误报「结构变了」。
    """
    parts: list[str] = []
    for table in sorted(probe):
        if table not in PUBLIC_SOURCE_TABLES:
            continue
        cols = ",".join(f"{c}:{probe[table][c]}" for c in sorted(probe[table]))
        parts.append(f"{table}({cols})")
    return hashlib.sha256("|".join(parts).encode("utf-8")).hexdigest()[:16]


@dataclass
class ResolvedTable:
    """映射 × 真实结构 = 本次实际可执行的东西。"""

    spec: TableSpec
    available: bool
    effective_fields: tuple[FieldSpec, ...] = ()
    missing_columns: tuple[str, ...] = ()
    skip_reason: str | None = None


@dataclass
class ResolvedDataset:
    mapping: DatasetMapping
    fingerprint: str
    tables: tuple[ResolvedTable, ...]
    degraded: list[dict[str, Any]] = field(default_factory=list)
    #: 破坏性变更（主键/游标列消失）。非空时默认拒绝导出——见 ON_MISSING 的说明。
    breaking: list[dict[str, Any]] = field(default_factory=list)

    @property
    def usable_tables(self) -> tuple[ResolvedTable, ...]:
        return tuple(t for t in self.tables if t.available)


def resolve(mapping: DatasetMapping, probe: dict[str, dict[str, str]]) -> ResolvedDataset:
    """把映射对齐到真实结构，产出「哪些表能导、哪些字段降级了」。

    设计取向：**能导就导，缺的记账**。整表缺失/字段缺失都不抛异常——
    客户临时撤掉一张表就整批失败，是最不必要的脆弱。
    """
    resolved: list[ResolvedTable] = []
    degraded: list[dict[str, Any]] = []
    breaking: list[dict[str, Any]] = []

    for spec in mapping.tables:
        if spec.mode == "query":
            missing = [s for s in spec.required_sources if s not in probe]
            if missing:
                resolved.append(ResolvedTable(
                    spec=spec,
                    available=False,
                    skip_reason=f"依赖表缺失: {', '.join(missing)}",
                ))
                degraded.append({
                    "table": spec.target,
                    "kind": "table_missing",
                    "detail": f"依赖表缺失: {', '.join(missing)}",
                })
            else:
                resolved.append(ResolvedTable(spec=spec, available=True))
            continue

        assert spec.source is not None
        if spec.source not in probe:
            resolved.append(ResolvedTable(
                spec=spec,
                available=False,
                skip_reason=f"源表缺失: {spec.source}",
            ))
            degraded.append({
                "table": spec.target,
                "kind": "table_missing",
                "detail": f"源表 {spec.source} 不存在",
            })
            continue

        real_cols = probe[spec.source]
        effective: list[FieldSpec] = []
        missing_cols: list[str] = []
        rejected_required: list[str] = []
        broken: list[str] = []

        for f in spec.fields:
            if f.column is None or f.column in real_cols:
                effective.append(f)
                continue
            missing_cols.append(f.column)
            if f.on_missing == "break":
                # 主键/游标消失：不降级、不猜、不停在这里记账都不行 —— 必须停机。
                broken.append(f.column)
                breaking.append({
                    "table": spec.target,
                    "column": f.column,
                    "field": f.target,
                    "detail": (
                        f"关键列 {f.column}（{f.target}）不存在。"
                        f"源侧可能改名/删列，继续导会静默产生错主键的数据"
                    ),
                })
            elif f.required or f.on_missing == "reject":
                rejected_required.append(f.column)
                degraded.append({
                    "table": spec.target,
                    "kind": "field_missing_reject",
                    "detail": f"必需列 {f.column} 不存在，该行会被拒绝",
                })
            else:
                effective.append(f)
                degraded.append({
                    "table": spec.target,
                    "kind": "field_missing_degrade",
                    "detail": f"列 {f.column} 不存在，字段 {f.target} 置空",
                })

        if broken:
            resolved.append(ResolvedTable(
                spec=spec,
                available=False,
                effective_fields=tuple(effective),
                missing_columns=tuple(missing_cols),
                skip_reason=f"破坏性结构变更：关键列缺失 {', '.join(broken)}",
            ))
            continue

        # 必需列全没了就没必要读这张表——读出来也是全 reject。
        if rejected_required and all(
            f.required and f.column in missing_cols for f in spec.fields
        ):
            resolved.append(ResolvedTable(
                spec=spec,
                available=False,
                effective_fields=tuple(effective),
                missing_columns=tuple(missing_cols),
                skip_reason="全部必需列缺失",
            ))
            continue

        resolved.append(ResolvedTable(
            spec=spec,
            available=True,
            effective_fields=tuple(effective),
            missing_columns=tuple(missing_cols),
        ))

    return ResolvedDataset(
        mapping=mapping,
        fingerprint=fingerprint(probe),
        tables=tuple(resolved),
        degraded=degraded,
        breaking=breaking,
    )
