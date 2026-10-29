"""从客户源库导出标准数据集。

## 四个可靠性要点（都不是可选的）

1. **一致性快照**：线上 SQLite 库正在被写入，裸开 `mode=ro` 可能读到 WAL 里未
   合并的中间态，甚至因拿不到 shm 而报错。先用 backup API 拷一份一致快照再读
   —— 对线上库是只读操作，不影响其写入。
2. **破坏性变更停机**：主键/游标列消失时直接抛 `BreakingSchemaChange`，**不产出
   任何文件**。宁可这一轮没数据，也不能让导入器把「主键全错的表」当全量新增写进去。
3. **原子落盘**：先写 `.tmp`，跑完再 `os.replace`。中途失败不留半成品。
4. **单表失败不炸全局**：某张表 SQL 出错（客户改结构、类型不兼容）只跳过这张表
   并记账。全量导出因为一张资讯表挂掉而白跑，是最没必要的损失。

## 为什么先写到本地 SQLite 而不是直接灌后端

后端导入接口是逐条 upsert，实测 8 条/秒。把「取数」和「灌数」解耦之后，
取数可以一次拿全、随时重放；灌数可以按批慢慢来，也可以在另一台机器上跑。
"""

from __future__ import annotations

import json
import os
import sqlite3
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator

from . import schema
from .mapping import (
    DatasetMapping,
    FieldSpec,
    ResolvedDataset,
    ResolvedTable,
    probe_sqlite,
    resolve,
)

#: 分块读取的行数。整表 fetchall 在 1.8 万行 × 富字段时会把内存吃掉几百 MB，
#: 而 fetchmany 的成本几乎为零。
READ_CHUNK = 1000

ISSUE_INVALID = "invalid"
ISSUE_UNKNOWN_ENUM = "unknown_enum"
ISSUE_OUT_OF_RANGE = "out_of_range"


class BreakingSchemaChange(RuntimeError):
    """源库发生破坏性结构变更，本轮拒绝导出。

    单独成类而不是复用 ValueError：调用方需要能区分「映射写错了」（人改配置即可）
    与「客户改了库」（要联系客户/重新核对映射），这两件事的处置完全不同。
    """

    def __init__(self, items: list[dict[str, Any]]):
        self.items = items
        detail = "; ".join(i["detail"] for i in items) or "未知"
        super().__init__(f"源库结构发生破坏性变更，已停止导出：{detail}")


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


@dataclass
class FieldStat:
    """单个字段的质量统计。漂移不是靠猜，是靠这些计数。"""

    nulls: int = 0
    invalid: int = 0
    unknown_enum: dict[str, int] = field(default_factory=dict)
    out_of_range: int = 0

    @property
    def has_problem(self) -> bool:
        return bool(self.invalid or self.unknown_enum or self.out_of_range)

    def to_dict(self, total: int) -> dict[str, Any]:
        d: dict[str, Any] = {
            "nulls": self.nulls,
            "invalid": self.invalid,
            "out_of_range": self.out_of_range,
        }
        if total:
            d["null_ratio"] = round(self.nulls / total, 4)
        if self.unknown_enum:
            d["unknown_enum"] = dict(
                sorted(self.unknown_enum.items(), key=lambda kv: -kv[1])[:10]
            )
        return d


@dataclass
class ExportReport:
    """导出结果。给人看，也给下一轮比对看。"""

    source_id: str
    dataset_path: str
    generated_at: str
    source_fingerprint: str
    elapsed_seconds: float
    row_counts: dict[str, int] = field(default_factory=dict)
    rejected: dict[str, int] = field(default_factory=dict)
    skipped_tables: dict[str, str] = field(default_factory=dict)
    degraded: list[dict[str, Any]] = field(default_factory=list)
    breaking: list[dict[str, Any]] = field(default_factory=list)
    field_stats: dict[str, FieldStat] = field(default_factory=dict)
    table_errors: dict[str, str] = field(default_factory=dict)
    warnings: list[str] = field(default_factory=list)
    snapshot_used: bool = False

    @property
    def total_rows(self) -> int:
        return sum(self.row_counts.values())

    def to_dict(self) -> dict[str, Any]:
        return {
            "dataset_version": schema.DATASET_VERSION,
            "source_id": self.source_id,
            "dataset_path": self.dataset_path,
            "generated_at": self.generated_at,
            "source_fingerprint": self.source_fingerprint,
            "snapshot_used": self.snapshot_used,
            "elapsed_seconds": round(self.elapsed_seconds, 2),
            "row_counts": self.row_counts,
            "total_rows": self.total_rows,
            "rejected": {k: v for k, v in self.rejected.items() if v},
            "skipped_tables": self.skipped_tables,
            "table_errors": self.table_errors,
            "breaking": self.breaking,
            "degraded": self.degraded,
            "field_stats": {
                k: v.to_dict(self.row_counts.get(k.split(".", 1)[0], 0))
                for k, v in sorted(self.field_stats.items())
                if v.has_problem or v.nulls
            },
            "warnings": self.warnings,
        }


# ---------------------------------------------------------------- 值转换


def coerce(value: Any, spec: FieldSpec) -> tuple[Any, str | None]:
    """按声明类型转换单个值，返回 (值, 问题码)。

    问题码为 None 表示干净。**空值不算问题**——缺失是常态，坏值才是信号。
    """
    if spec.const is not None:
        return spec.const, None

    if value is None:
        return spec.default, None
    if isinstance(value, str) and not value.strip():
        return spec.default, None

    ftype = spec.type

    if ftype in ("str", "text", "datetime"):
        text = str(value).strip()
        return (text or spec.default), None

    if ftype == "bool":
        if isinstance(value, bool):
            return value, None
        low = str(value).strip().lower()
        if low in ("1", "true", "t", "yes", "y"):
            return True, None
        if low in ("0", "false", "f", "no", "n"):
            return False, None
        return spec.default, ISSUE_INVALID

    if ftype == "int":
        try:
            num: float = float(value)
        except (TypeError, ValueError):
            return spec.default, ISSUE_INVALID
        if num != int(num):
            return spec.default, ISSUE_INVALID
        return _check_range(int(num), spec)

    if ftype == "float":
        try:
            num = float(value)
        except (TypeError, ValueError):
            return spec.default, ISSUE_INVALID
        return _check_range(num, spec)

    if ftype == "bracket_list":
        items = _parse_bracket_list(value)
        if items:
            return json.dumps(items, ensure_ascii=False), None
        # 源列**有值**但拆不出别名（典型是空壳 `{\n}`）：这是源站明确说「没有别名」，
        # 必须写成 `[]`（后端三态里的「清空」），不能落到默认的 null（「不覆盖」）。
        # 用 null 的话，库里之前灌进去的脏值（`["{\n}"]`）永远洗不掉——
        # 后端按契约「null 不覆盖」会一直留着它，客户端就会露出花括号。#273
        # 源列本身是 NULL / 空串时在上面就被短路成 default 了，走不到这里，
        # 也就是「源站没给这个字段」仍然是 null，不会误清库里已有的好别名。
        return "[]", None

    if ftype in ("json_list", "json_obj"):
        parsed = value
        if isinstance(value, (str, bytes)):
            try:
                parsed = json.loads(value)
            except (TypeError, ValueError):
                return spec.default, ISSUE_INVALID
        want_list = ftype == "json_list"
        if want_list and not isinstance(parsed, list):
            return spec.default, ISSUE_INVALID
        if not want_list and not isinstance(parsed, dict):
            return spec.default, ISSUE_INVALID
        # 必须序列化回 JSON 文本：sqlite3 无法绑定 Python 的 list/dict，
        # 直接返回会在写入时抛 InterfaceError（一张表整体被跳过，很难查）。
        return json.dumps(parsed, ensure_ascii=False), None

    if ftype == "enum":
        key = str(value).strip()
        mapping = spec.enum_map or {}
        if key in mapping:
            return mapping[key], None
        # 未知枚举是最危险的漂移：客户新增一个取值，我们静默变 null 就"消失"了。
        # 置 default 但记账，导出报告会把它顶到台面上。
        return spec.default, f"{ISSUE_UNKNOWN_ENUM}:{key}"

    return value, ISSUE_INVALID  # pragma: no cover - FIELD_TYPES 已穷举


def _parse_bracket_list(value: Any) -> list[str]:
    """把 ``{\\n[别名一]\\n[别名二]\\n}`` 这种括号包裹的多行文本拆成字符串列表。

    来源形态有两种，都要认：

    1. 源列是 **JSON 数组，但数组里只有一个元素**，元素本身才是那坨文本——
       首站的 ``contents.aliases`` 就是 ``'["{\\n[EVA]\\n[新世纪福音战士]\\n}"]'``，
       18,828 行 100% 是这个形状。``json_list`` 只能解析到最外层数组，
       于是整坨文本变成一个元素，直接下发的话客户端会看到 ``{`` ``[`` ``}``；
    2. 源列直接就是那坨文本（客户自建站常见）。

    两种都先归一成文本，再按行拆：去 ``{`` ``}`` 行、去每行的 ``[`` ``]``、
    丢空行、按原顺序去重。拆不出东西就返回空列表，由调用方按「没有」处理。
    """
    if value is None:
        return []
    if isinstance(value, (list, tuple)):
        text = "\n".join(str(item) for item in value)
    elif isinstance(value, bytes):
        text = value.decode("utf-8", "replace")
    else:
        text = str(value)

    stripped = text.strip()
    if stripped.startswith("["):
        try:
            parsed = json.loads(stripped)
        except (TypeError, ValueError):
            parsed = None
        if isinstance(parsed, (list, tuple)):
            text = "\n".join(str(item) for item in parsed)
        elif isinstance(parsed, str):
            text = parsed

    items: list[str] = []
    for line in str(text).splitlines():
        line = line.strip()
        if line in ("{", "}"):
            continue
        line = line.strip("[]").strip()
        if line and line not in items:
            items.append(line)
    return items


def _check_range(num: float, spec: FieldSpec) -> tuple[Any, str | None]:
    if spec.minimum is not None and num < spec.minimum:
        return spec.default, ISSUE_OUT_OF_RANGE
    if spec.maximum is not None and num > spec.maximum:
        return spec.default, ISSUE_OUT_OF_RANGE
    return num, None


def _record(stat: FieldStat, issue: str | None) -> None:
    if issue is None:
        return
    if issue.startswith(ISSUE_UNKNOWN_ENUM + ":"):
        raw = issue.split(":", 1)[1]
        stat.unknown_enum[raw] = stat.unknown_enum.get(raw, 0) + 1
    elif issue == ISSUE_INVALID:
        stat.invalid += 1
    elif issue == ISSUE_OUT_OF_RANGE:
        stat.out_of_range += 1


# ---------------------------------------------------------------- 源读取


def open_source(
    src: Path, *, snapshot_dir: Path | None = None
) -> tuple[sqlite3.Connection, Path | None]:
    """打开源库。优先用 backup API 拿一致快照，拿不到再退回直接只读。

    返回 (连接, 快照路径)。快照路径非 None 时调用方负责删除。
    """
    if not src.exists():
        raise FileNotFoundError(f"源库不存在: {src}")

    ro_uri = f"file:{src.as_posix()}?mode=ro"
    ro = sqlite3.connect(ro_uri, uri=True, timeout=15.0)
    ro.execute("select count(*) from sqlite_master").fetchone()

    if snapshot_dir is None:
        return ro, None

    snapshot_dir.mkdir(parents=True, exist_ok=True)
    snapshot = snapshot_dir / f"src-snapshot-{os.getpid()}.db"
    snapshot.unlink(missing_ok=True)
    try:
        dst = sqlite3.connect(str(snapshot))
        try:
            with dst:
                ro.backup(dst)
        finally:
            dst.close()
        ro.close()
        conn = sqlite3.connect(f"file:{snapshot.as_posix()}?mode=ro", uri=True)
        return conn, snapshot
    except sqlite3.Error:
        # 快照失败不致命：退回读原库，报告里会说明「没用上快照」
        snapshot.unlink(missing_ok=True)
        conn = sqlite3.connect(ro_uri, uri=True, timeout=15.0)
        return conn, None


def _build_dataset(out: Path) -> sqlite3.Connection:
    """建目标库。先删后建——数据集是幂等产物，不是需要保留的台账。"""
    out.unlink(missing_ok=True)
    out.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(out))
    conn.executescript(schema.DDL)
    return conn


def _target_columns(out: sqlite3.Connection, table: str) -> list[str]:
    return [r[1] for r in out.execute(f'PRAGMA table_info("{table}")').fetchall()]


# ---------------------------------------------------------------- 导出主体


def export_dataset(
    source_db: str | Path,
    out_path: str | Path,
    mapping_path: str | Path,
    *,
    source_id: str | None = None,
    max_rows: int | None = None,
    snapshot: bool = True,
    report_path: str | Path | None = None,
    allow_breaking: bool = False,
) -> ExportReport:
    """执行一次导出。返回报告，同时把报告落盘（若给了 report_path）。

    `allow_breaking=True` 是逃生门：确认过「源库确实改了主键、映射已同步更新」
    之后才该用它。默认 False —— 破坏性变更就该停下来等人看。
    """
    started = time.time()
    src_path = Path(source_db)
    out = Path(out_path)
    mapping = DatasetMapping.load(mapping_path)

    conn, snapshot_path = open_source(
        src_path, snapshot_dir=(out.parent if snapshot else None)
    )
    try:
        probe = probe_sqlite(conn)
        resolved = resolve(mapping, probe)

        if resolved.breaking and not allow_breaking:
            raise BreakingSchemaChange(resolved.breaking)

        report = ExportReport(
            source_id=source_id or mapping.source_id,
            dataset_path=str(out),
            generated_at=_utc_now(),
            source_fingerprint=resolved.fingerprint,
            elapsed_seconds=0.0,
            degraded=list(resolved.degraded),
            breaking=list(resolved.breaking),
            snapshot_used=snapshot_path is not None,
        )
        for rt in resolved.tables:
            if not rt.available:
                report.skipped_tables[rt.spec.target] = rt.skip_reason or "不可用"
        if snapshot and snapshot_path is None:
            report.warnings.append(
                "无法创建一致性快照，已直接读源库；导出期间若源库正在写入，"
                "快照边界可能不一致"
            )
        if resolved.breaking:
            report.warnings.append(
                f"已越过 {len(resolved.breaking)} 项破坏性变更（allow_breaking）。"
                f"确认映射已同步更新，否则主键可能是错的"
            )

        tmp = out.with_suffix(out.suffix + ".tmp")
        out_conn = _build_dataset(tmp)
        try:
            with out_conn:
                for rt in resolved.usable_tables:
                    _export_table(conn, out_conn, rt, report, max_rows)
                _write_meta(out_conn, report)
            out_conn.execute("ANALYZE")
        finally:
            out_conn.close()

        os.replace(tmp, out)
        report.elapsed_seconds = time.time() - started
        _add_warnings(report)

        if report_path is not None:
            rp = Path(report_path)
            rp.parent.mkdir(parents=True, exist_ok=True)
            rp.write_text(
                json.dumps(report.to_dict(), ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
        return report
    finally:
        conn.close()
        if snapshot_path is not None:
            snapshot_path.unlink(missing_ok=True)


def _iter_source_rows(
    conn: sqlite3.Connection,
    spec_source: str,
    where: str | None,
    max_rows: int | None,
) -> Iterator[dict[str, Any]]:
    sql = f'select * from "{spec_source}"'
    if where:
        sql += f" where ({where})"
    cur = conn.execute(sql)
    columns = [d[0] for d in cur.description]
    yielded = 0
    while True:
        chunk = cur.fetchmany(READ_CHUNK)
        if not chunk:
            return
        for row in chunk:
            yield dict(zip(columns, row))
            yielded += 1
            if max_rows is not None and yielded >= max_rows:
                return


def _export_table(
    src: sqlite3.Connection,
    out: sqlite3.Connection,
    rt: ResolvedTable,
    report: ExportReport,
    max_rows: int | None,
) -> None:
    target = rt.spec.target
    try:
        if rt.spec.mode == "query":
            _export_query(src, out, rt, report, max_rows)
        else:
            _export_mapped(src, out, rt, report, max_rows)
    except sqlite3.Error as exc:
        # 单表失败：记账、跳过，不让整批导出白跑
        report.table_errors[target] = f"{type(exc).__name__}: {exc}"
        report.skipped_tables[target] = "执行出错，已跳过"


def _export_mapped(
    src: sqlite3.Connection,
    out: sqlite3.Connection,
    rt: ResolvedTable,
    report: ExportReport,
    max_rows: int | None,
) -> None:
    target = rt.spec.target
    assert rt.spec.source is not None

    cols = _target_columns(out, target)
    fields = [f for f in rt.effective_fields if f.target in cols]
    if not fields:
        report.skipped_tables[target] = "映射字段与目标表列无交集"
        return

    placeholders = ",".join("?" * len(fields))
    col_names = ",".join(f'"{f.target}"' for f in fields)
    insert_sql = (
        f'INSERT OR REPLACE INTO "{target}" ({col_names}) VALUES ({placeholders})'
    )

    stats = {
        f.target: report.field_stats.setdefault(f"{target}.{f.target}", FieldStat())
        for f in fields
    }
    rows = 0
    rejected = 0

    for raw in _iter_source_rows(src, rt.spec.source, rt.spec.filter, max_rows):
        values: list[Any] = []
        reject_reason: str | None = None

        for f in fields:
            # const 字段不读源列（例如 rating_scale 恒为 "0-10"），
            # 必须先处理——否则会掉进下面的空值分支被当成"源侧没数据"。
            if f.const is not None:
                values.append(f.const)
                continue

            value = raw.get(f.column) if f.column else None
            if value is None or (isinstance(value, str) and not value.strip()):
                stats[f.target].nulls += 1
                if f.required and f.on_missing == "reject":
                    reject_reason = f"必需字段 {f.target} 为空"
                values.append(f.default)
                continue

            coerced, issue = coerce(value, f)
            _record(stats[f.target], issue)
            if coerced is None:
                stats[f.target].nulls += 1
                if f.required:
                    reject_reason = reject_reason or f"必需字段 {f.target} 无法转换"
            values.append(coerced)

        if reject_reason is not None:
            rejected += 1
            continue

        out.execute(insert_sql, values)
        rows += 1

    report.row_counts[target] = rows
    if rejected:
        report.rejected[target] = rejected


def _export_query(
    src: sqlite3.Connection,
    out: sqlite3.Connection,
    rt: ResolvedTable,
    report: ExportReport,
    max_rows: int | None,
) -> None:
    """query 模式：SQL 自己产出标准列名，导出器只做列交集与写入。

    这让「需要 join 才能表达」的关系（作品↔标签、资讯↔作品）不必给映射语言
    加一套 DSL —— 多一种语法就多一处要维护、要测试的东西。SQL 是数据映射的
    通用语，dbt/Airbyte 最终都收敛到这里。
    """
    target = rt.spec.target
    assert rt.spec.sql is not None
    cols = _target_columns(out, target)

    cur = src.execute(rt.spec.sql)
    src_cols = [d[0] for d in cur.description]
    usable = [c for c in src_cols if c in cols]
    if not usable:
        report.skipped_tables[target] = "query 输出列与目标表列无交集"
        return

    placeholders = ",".join("?" * len(usable))
    col_names = ",".join(f'"{c}"' for c in usable)
    insert_sql = (
        f'INSERT OR REPLACE INTO "{target}" ({col_names}) VALUES ({placeholders})'
    )
    idx = [src_cols.index(c) for c in usable]

    rows = 0
    stopped = False
    while not stopped:
        chunk = cur.fetchmany(READ_CHUNK)
        if not chunk:
            break
        for row in chunk:
            out.execute(insert_sql, [row[i] for i in idx])
            rows += 1
            if max_rows is not None and rows >= max_rows:
                stopped = True
                break

    report.row_counts[target] = rows


def _write_meta(out: sqlite3.Connection, report: ExportReport) -> None:
    meta = {
        schema.META_SCHEMA_VERSION: schema.DATASET_VERSION,
        schema.META_EXPORTER_VERSION: schema.EXPORTER_VERSION,
        schema.META_SOURCE_ID: report.source_id,
        schema.META_GENERATED_AT: report.generated_at,
        schema.META_SOURCE_FINGERPRINT: report.source_fingerprint,
        schema.META_ROW_COUNTS: json.dumps(report.row_counts, ensure_ascii=False),
        schema.META_DEGRADED: json.dumps(report.degraded, ensure_ascii=False),
    }
    out.executemany(
        "INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", list(meta.items())
    )


#: 空值率告警的最小样本量。6 条样本里 6 个空 = 100%，但那只是表小，
#: 不是字段废弃。低于这个量级只统计不起警报，否则小站/小表全是噪音，
#: 真信号会被淹掉。
MIN_ROWS_FOR_NULL_WARNING = 50


def _add_warnings(report: ExportReport) -> None:
    """把统计翻译成人能看的一句话。报告不是给程序看的日志，是给人做决定的。"""
    for key, stat in sorted(report.field_stats.items()):
        table = key.split(".", 1)[0]
        total = report.row_counts.get(table, 0)
        if not total:
            continue
        if stat.invalid:
            report.warnings.append(
                f"{key}: {stat.invalid}/{total} 条无法按声明类型转换，已置空——"
                f"源侧类型可能变了"
            )
        if stat.out_of_range:
            report.warnings.append(
                f"{key}: {stat.out_of_range}/{total} 条越界，已置空——检查取值范围口径"
            )
        if stat.unknown_enum:
            top = sorted(stat.unknown_enum.items(), key=lambda kv: -kv[1])[:5]
            detail = ", ".join(f"{k}×{v}" for k, v in top)
            report.warnings.append(
                f"{key}: 出现 enum_map 未覆盖的取值（{detail}）——"
                f"需要在映射里补 enum_map，否则这些行该字段会变空"
            )
        ratio = stat.nulls / total
        if ratio >= 0.9 and total >= MIN_ROWS_FOR_NULL_WARNING:
            report.warnings.append(
                f"{key}: 空值率 {ratio:.0%}（{total} 条），基本等于没数据——"
                f"确认源列是否已废弃"
            )


# ---------------------------------------------------------------- 下游校验


def read_meta(dataset_path: str | Path) -> dict[str, str]:
    """读数据集的 meta，供导入器做版本校验。"""
    p = Path(dataset_path)
    if not p.exists():
        raise FileNotFoundError(f"数据集不存在: {p}")
    conn = sqlite3.connect(f"file:{p.as_posix()}?mode=ro", uri=True)
    try:
        rows = conn.execute("select key, value from meta").fetchall()
        return {str(k): str(v) for k, v in rows}
    finally:
        conn.close()


def assert_compatible(dataset_path: str | Path) -> dict[str, str]:
    """版本校验：不认识的格式直接拒收，别让它混进导入流程。

    版本不匹配时不做「尽力而为」的兼容——字段语义可能已经变了（比如
    rating_scale 从 0-10 改成 0-100），猜着读比不读更糟。
    """
    meta = read_meta(dataset_path)
    version = meta.get(schema.META_SCHEMA_VERSION)
    if version != schema.DATASET_VERSION:
        raise ValueError(
            f"数据集格式版本 {version!r} 与本导入器支持的 "
            f"{schema.DATASET_VERSION!r} 不一致，拒绝导入"
        )
    if not meta.get(schema.META_SOURCE_ID):
        raise ValueError("数据集缺少 source_id，无法确定来源")
    return meta
