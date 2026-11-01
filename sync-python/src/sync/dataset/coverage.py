"""数据集覆盖率报告。

扫描**已导出的标准数据集 SQLite**（规范化产物，不是客户源库），按 work_type
统计各字段填充率，并算出「有封面可上线的作品数」。这是看清「发给后端的东西
到底有多少料」最快的办法，也是决定「哪些缺口值得补」的依据。

为什么扫数据集而不是源库：
- 数据集是我们真正会发给后端的形态，覆盖率就该按「后端能展示什么」算；
- 源库有脏数据/未映射字段，扫它只会稀释信号；
- 数据集 schema 固定（我们自己的），不必为客户的表结构写一堆分支。

people 表有两件要分开看的事，报告里也分两段：

- **行数**：v2 起导出器按映射整表照搬源库 `entities`，行数随源库走，
  不是「恒空」；
- **id 对齐**：`people.source_id` 是源站 `entities` 的本地自增 id，而
  `work_credits` / `work_cast.person_ref` 存的是 Bangumi 人物 id。两套空间
  直接 join 会挂错名，所以单独算「person_ref 有多少能在 people 里找到」——
  对齐率不足 100% 就是这件事还没做，见 `docs/person-id-unification.md`。

传 `--source-db` 时顺带扫源库 `entities` 表，给出「源侧到底有多少人物/公司
主数据可用」。

用法：
    python -m sync --coverage-report --dataset-in runs/dataset.db
    python -m sync --coverage-report --dataset-in runs/dataset.db \
        --source-db /path/to/source.sqlite --coverage-json out.json
"""

from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

#: 类型展示顺序。不在其中的类型会追加在后面。
WORK_TYPE_ORDER = ("anime", "comic", "game", "novel")

#: 关注的 works 字段：(列名, 中文标签)。列不存在时报告里标「无此列」。
WORK_FIELDS: list[tuple[str, str]] = [
    ("title", "主标题"),
    ("title_original", "原名"),
    ("summary", "简介"),
    ("cover_url", "封面"),
    ("rating_value", "评分"),
    ("aliases_json", "别名"),
    ("release_year", "年份"),
    ("episodes", "集数"),
    ("media", "媒介"),
]

#: 关联表：(表名, 中文标签)。统计「至少有 1 条关联的作品占比」。
RELATION_TABLES: list[tuple[str, str]] = [
    ("work_tags", "标签"),
    ("work_credits", "制作人员"),
    ("work_cast", "角色声优"),
    ("work_studios", "制作公司"),
]


def _connect(path: str | Path) -> sqlite3.Connection:
    conn = sqlite3.connect(f"file:{Path(path).as_posix()}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def coverage_report(
    dataset_path: str | Path,
    *,
    source_db: str | Path | None = None,
    json_path: str | Path | None = None,
) -> dict[str, Any]:
    """扫描数据集，返回结构化覆盖率报告（dict）。

    `source_db` 非 None 时额外扫源库 `entities` 表，给出人物/公司主数据可用量。
    `json_path` 非 None 时把报告落盘为 JSON。
    """
    conn = _connect(dataset_path)
    try:
        meta = {}
        try:
            for r in conn.execute("select key, value from meta"):
                meta[r["key"]] = r["value"]
        except sqlite3.Error:
            pass

        cols = {r[1] for r in conn.execute("PRAGMA table_info(works)")}

        total = conn.execute("select count(*) from works").fetchone()[0]
        by_type: dict[str, int] = {}
        for r in conn.execute(
            "select work_type, count(*) as c from works group by work_type"
        ):
            by_type[r["work_type"]] = r["c"]
        types = [t for t in WORK_TYPE_ORDER if t in by_type] + [
            t for t in by_type if t not in WORK_TYPE_ORDER
        ]

        def _fill(col: str) -> dict[str, Any]:
            """某 works 字段的填充统计：总计 + 按类型非空数。"""
            total_nn = conn.execute(
                f"select count(*) from works"
                f" where {col} is not null and trim({col}) <> ''"
            ).fetchone()[0]
            per: dict[str, int] = {}
            for t in types:
                n = conn.execute(
                    f"select count(*) from works"
                    f" where work_type = ? and {col} is not null"
                    f" and trim({col}) <> ''",
                    (t,),
                ).fetchone()[0]
                per[t] = n
            return {"total": total_nn, "by_type": per}

        field_stats: dict[str, Any] = {}
        for col, label in WORK_FIELDS:
            if col not in cols:
                field_stats[col] = {"label": label, "available": False}
                continue
            field_stats[col] = {
                "label": label,
                "available": True,
                **_fill(col),
            }

        def _rel_cover(tbl: str) -> dict[str, Any]:
            exists = conn.execute(
                "select count(*) from sqlite_master"
                " where type='table' and name=?",
                (tbl,),
            ).fetchone()[0]
            if not exists:
                return {"label": _rel_label(tbl), "exists": False}
            distinct = conn.execute(
                f"select count(distinct source_id) from {tbl}"
            ).fetchone()[0]
            per: dict[str, Any] = {}
            for t in types:
                n = conn.execute(
                    f"select count(*) from works w where w.work_type = ?"
                    f" and exists (select 1 from {tbl} t"
                    f" where t.source_id = w.source_id)",
                    (t,),
                ).fetchone()[0]
                per[t] = {"covered": n, "total": by_type.get(t, 0)}
            return {
                "label": _rel_label(tbl),
                "exists": True,
                "distinct_works": distinct,
                "by_type": per,
            }

        rel_stats: dict[str, Any] = {}
        for tbl, _ in RELATION_TABLES:
            rel_stats[tbl] = _rel_cover(tbl)

        # people 主数据：行数是一件事，与 person_ref 的 id 对齐是另一件事
        people_exists = conn.execute(
            "select count(*) from sqlite_master where type='table' and name='people'"
        ).fetchone()[0]
        people_rows = 0
        people_with_bgm = 0
        if people_exists:
            people_rows = conn.execute("select count(*) from people").fetchone()[0]
            try:
                people_with_bgm = conn.execute(
                    "select count(*) from people"
                    " where bangumi_person_id is not null"
                    " and trim(bangumi_person_id) <> ''"
                ).fetchone()[0]
            except sqlite3.Error:
                pass
        # 必须在连接关闭前算：对齐率要 join people 与关系表
        id_alignment = _person_id_alignment(conn, people_exists=bool(people_exists))

        # 可上线数（有封面），这是「无封面不展示」口径下的实际可发量
        online_total = conn.execute(
            "select count(*) from works"
            " where cover_url is not null and trim(cover_url) <> ''"
        ).fetchone()[0]
        online_by_type: dict[str, int] = {}
        for t in types:
            n = conn.execute(
                "select count(*) from works"
                " where work_type = ? and cover_url is not null"
                " and trim(cover_url) <> ''",
                (t,),
            ).fetchone()[0]
            online_by_type[t] = n
    finally:
        conn.close()

    report: dict[str, Any] = {
        "dataset_path": str(dataset_path),
        "meta": meta,
        "total_works": total,
        "by_type": by_type,
        "field_fill": field_stats,
        "relation_coverage": rel_stats,
        "people": {
            "exists": bool(people_exists),
            "rows": people_rows,
            "with_bangumi_id": people_with_bgm,
            "id_alignment": id_alignment,
        },
        "online_with_cover": {"total": online_total, "by_type": online_by_type},
    }

    if source_db is not None:
        report["source_entities"] = _scan_entities(source_db)

    if json_path is not None:
        p = Path(json_path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(
            json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
        )
    return report


def _person_id_alignment(
    conn: sqlite3.Connection, *, people_exists: bool
) -> dict[str, Any]:
    """算 `people.source_id` 与关系表 `person_ref` 的 id 对齐情况。

    两个数必须分开看：行数是「导出了多少人物」，对齐率是「这些人能不能被
    关系表引到」。两套 id 空间并存时（people 用源站自增 id、person_ref 用
    Bangumi 人物 id），对齐率会接近 0——这不是导入 bug，是口径没统一。
    """
    if not people_exists:
        return {"available": False}

    tables = {
        r[0] for r in conn.execute("select name from sqlite_master where type='table'")
    }
    ref_tables = [t for t in ("work_cast", "work_credits") if t in tables]
    people_distinct = conn.execute(
        "select count(distinct source_id) from people"
    ).fetchone()[0]

    if not ref_tables:
        return {
            "available": True,
            "people_distinct": people_distinct,
            "refs_by_table": {},
            "refs_total": 0,
            "refs_matched": 0,
            "refs_dangling": 0,
            "people_unreferenced": people_distinct,
        }

    refs_by_table: dict[str, int] = {}
    for table in ref_tables:
        refs_by_table[table] = conn.execute(
            f"select count(distinct person_ref) from {table}"
            " where person_ref is not null and trim(person_ref) <> ''"
        ).fetchone()[0]

    # union 天然去重：同一人既是声优又是制作人员时只算一个
    ref_sql = " union ".join(
        f"select person_ref from {table}"
        " where person_ref is not null and trim(person_ref) <> ''"
        for table in ref_tables
    )
    refs_total = conn.execute(f"select count(*) from ({ref_sql})").fetchone()[0]
    refs_matched = conn.execute(
        f"select count(*) from ({ref_sql}) r"
        " join people p on p.source_id = r.person_ref"
    ).fetchone()[0]
    not_referenced = " and ".join(
        f"not exists (select 1 from {table} where person_ref = p.source_id)"
        for table in ref_tables
    )
    people_unreferenced = conn.execute(
        f"select count(*) from people p where {not_referenced}"
    ).fetchone()[0]

    return {
        "available": True,
        "people_distinct": people_distinct,
        "refs_by_table": refs_by_table,
        "refs_total": refs_total,
        "refs_matched": refs_matched,
        "refs_dangling": refs_total - refs_matched,
        "people_unreferenced": people_unreferenced,
    }


def _rel_label(tbl: str) -> str:
    for t, label in RELATION_TABLES:
        if t == tbl:
            return label
    return tbl


def _scan_entities(source_db: str | Path) -> dict[str, Any]:
    """扫源库 `entities` 表，给出人物/公司主数据可用量——#1 的范围依据。

    源库未必有这张表（例如 bangumi 档案不含 entities），没有就如实标 absent。
    """
    conn = _connect(source_db)
    try:
        exists = conn.execute(
            "select count(*) from sqlite_master where type='table' and name='entities'"
        ).fetchone()[0]
        if not exists:
            return {"exists": False}
        total = conn.execute("select count(*) from entities").fetchone()[0]
        by_type: dict[str, int] = {}
        try:
            for r in conn.execute(
                "select entity_type, count(*) c from entities group by entity_type"
            ):
                by_type[r["entity_type"] or "(空)"] = r["c"]
        except sqlite3.Error:
            pass
        with_bgm = 0
        try:
            with_bgm = conn.execute(
                "select count(*) from entities"
                " where bangumi_person_id is not null"
                " and trim(bangumi_person_id) <> ''"
            ).fetchone()[0]
        except sqlite3.Error:
            pass
        return {
            "exists": True,
            "total": total,
            "by_type": by_type,
            "with_bangumi_person_id": with_bgm,
        }
    finally:
        conn.close()


# ---------------------------------------------------------------- 人类可读


def format_coverage_report(report: dict[str, Any]) -> str:
    """把结构化报告渲染成终端可看的文本。"""
    L: list[str] = []
    L.append("数据集覆盖率报告")
    L.append(f"数据集: {report['dataset_path']}")
    meta = report.get("meta", {})
    if meta:
        ver = meta.get("dataset_version", "?")
        src = meta.get("source_id", "?")
        gen = meta.get("generated_at", "?")
        L.append(f"版本: {ver}  来源: {src}  生成: {gen}")
    L.append("")

    total = report["total_works"]
    by_type = report["by_type"]
    L.append(f"作品总数: {total}")
    if by_type:
        L.append(
            "  类型分布: "
            + "  ".join(f"{k}={v}" for k, v in by_type.items())
        )
    types = list(by_type.keys())
    L.append("")

    # ---- 字段填充率 ----
    L.append("== 字段填充率（非空作品占比；总计列=有该字段的作品数，类型列=类型内占比）==")
    header = f"  {'字段':<8s}{'总计':>8s}" + "".join(f"{t:>9s}" for t in types)
    L.append(header)
    for col, info in report["field_fill"].items():
        if not info.get("available", False):
            L.append(f"  {info['label']:<8s}{'无此列':>10s}")
            continue
        total_nn = info["total"]
        cells = "".join(
            (f"{100*info['by_type'].get(t, 0)/by_type[t]:>8.1f}%"
             if by_type.get(t) else f"{'-':>9s}")
            for t in types
        )
        L.append(f"  {info['label']:<8s}{total_nn:>8d}{cells}")
    L.append("")

    # ---- 关联覆盖 ----
    L.append("== 关联数据覆盖（至少有 1 条关联的作品占比）==")
    L.append(f"  {'关联':<10s}{'总覆盖':>10s}" + "".join(f"{t:>10s}" for t in types))
    for tbl, info in report["relation_coverage"].items():
        if not info.get("exists", False):
            L.append(f"  {info['label']:<10s}{'无此表':>12s}")
            continue
        per = info["by_type"]
        cells = "".join(
            (f"{100*per[t]['covered']/per[t]['total']:>9.1f}%"
             if per[t]["total"] else f"{'-':>10s}")
            for t in types
        )
        tot_cov = sum(per[t]["covered"] for t in types)
        L.append(f"  {info['label']:<10s}{tot_cov:>10d}{cells}")
    L.append("")

    # ---- 可上线数 ----
    L.append("== 可上线数（有封面，按「无封面不展示」口径）==")
    oc = report["online_with_cover"]
    L.append(
        f"  总计: {oc['total']} / {total} ({100*oc['total']/total:.1f}%)"
        if total else "  总计: 0"
    )
    for t in types:
        n = oc["by_type"].get(t, 0)
        tt = by_type.get(t, 0)
        L.append(f"    {t:8s} {n} / {tt} ({100*n/tt:.1f}%)" if tt else f"    {t:8s} -")
    L.append("")

    # ---- people ----
    L.append("== people 主数据 ==")
    pe = report["people"]
    if not pe["exists"]:
        L.append("  数据集无 people 表（v1 或更早，未含人物主数据）")
    elif pe["rows"] == 0:
        L.append("  数据集 people 表: 0 行（源库 entities 为空，或映射未启用）")
    else:
        L.append(
            f"  数据集 people 表: {pe['rows']} 行，"
            f"其中带 bangumi_person_id {pe['with_bangumi_id']} 行"
        )
    L.append("")

    # ---- 人物 id 对齐（people.source_id ↔ person_ref）----
    al = pe.get("id_alignment") or {}
    if al.get("available"):
        L.append("== 人物 id 对齐（people.source_id ↔ 关系表 person_ref）==")
        per = al.get("refs_by_table") or {}
        detail = " / ".join(f"{_rel_label(t)} {n}" for t, n in per.items())
        L.append(
            f"  关系表引用去重: {al['refs_total']} 个 id"
            + (f"（{detail}）" if detail else "")
        )
        refs_total = al["refs_total"]
        rate = 100 * al["refs_matched"] / refs_total if refs_total else 0.0
        L.append(f"  能在 people 里找到: {al['refs_matched']} ({rate:.1f}%)")
        L.append(f"  悬空引用: {al['refs_dangling']}")
        L.append(f"  people 里从未被引用: {al['people_unreferenced']} 行")
        if refs_total and rate < 100.0:
            L.append(
                "  说明: 对齐率不足 100% 表示两套 id 空间并存，直接 join 会挂错名"
            )
            L.append("        （见 docs/person-id-unification.md）")
        L.append("")

    # ---- 源库 entities（#1 范围依据）----
    se = report.get("source_entities")
    if se is not None:
        L.append("== 源库 entities（#1 可 emit 的源侧主数据量）==")
        if not se.get("exists", False):
            L.append("  源库无 entities 表（此来源不含人物/公司主数据）")
        else:
            L.append(f"  总行数: {se['total']}")
            if se["by_type"]:
                L.append(
                    "  类型分布: "
                    + "  ".join(f"{k}={v}" for k, v in se["by_type"].items())
                )
            L.append(
                f"  带 bangumi_person_id: {se['with_bangumi_person_id']}"
            )
        L.append("")

    return "\n".join(L)
