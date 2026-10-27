"""数据集变更感知：这一次比上一次多了什么、改了什么、少了什么。

## 为什么不是「靠源侧 updated_at」

增量同步最直觉的做法是问源库「谁在某个时间点之后改过」，这要求源表有
`updated_at`。但把这条路当**前提**有两个硬问题：

1. **它解决不了删除**。`updated_at` 只能告诉你「还在表里的行谁变了」；
   源站删掉的作品根本不在表里，永远不会被扫到。而后端是 `(source, source_id)`
   的 upsert，没有删除信号就意味着**删掉的作品会一直留着**。
2. **它要改客户的表**。客户库结构是客户的，能不改就不改。

所以这里用的是**内容寻址**：为每个实体算一个指纹，两份指纹对比即可得到
`added / changed / deleted` 三个集合。删除是「上次有、这次没有」，天然成立；
客户表一个字都不用动。

代价是要读一遍全量。这个代价值得付——首站全量导出实测 618,853 行 / 12.1 秒，
比维护一套「客户必须配合改表」的游标便宜得多。等哪天全量真的贵了（数据量涨一个
量级、或跨机每日要传几十 MB），再把源侧游标当**读侧优化**补上，那时它也只是
省读的时间，不能取代这里的删除检测。

## 为什么按「实体」而不是按「行」

投递单位是作品（`ImportItem`），不是单行。一个作品的内容散在 `works` 加 6 张
关联表里，按行算指纹会把「同一个作品改了」拆成 7 条互不相干的记录，投递侧还得
自己聚合回去。按实体算一次，得到的直接就是「这个作品变了」。

标签词表与系列是全局小表，不归属任何单个作品，单独算。
"""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Mapping, Sequence

#: manifest 格式版本。结构变更必须递增，读旧文件时据此判断能否直接比对。
MANIFEST_VERSION = "1"

KIND_WORKS = "works"
KIND_ARTICLES = "articles"
KIND_SCHEDULES = "schedules"
KIND_TAGS = "tags"
KIND_SERIES = "series"


@dataclass(frozen=True)
class EntitySpec:
    """一类实体的指纹范围：主表 + 归属于它的子表。

    `children` 里的表都带一个指向主表键的外键列（名字不一定都叫 `source_id`，
    例如 `article_links.article_source_id`），所以外键列名要显式写出来。
    """

    kind: str
    table: str
    key: str
    children: tuple[tuple[str, str], ...] = ()


#: 实体定义。新增归属表（比如以后加 `work_staff`）只需在这里挂上，
#: 指纹范围随之扩大，不用改算法。
ENTITY_SPECS: tuple[EntitySpec, ...] = (
    EntitySpec(
        kind=KIND_WORKS,
        table="works",
        key="source_id",
        children=(
            ("work_tags", "source_id"),
            ("work_facts", "source_id"),
            ("work_credits", "source_id"),
            ("work_cast", "source_id"),
            ("work_studios", "source_id"),
            ("work_relations", "source_id"),
        ),
    ),
    EntitySpec(
        kind=KIND_ARTICLES,
        table="articles",
        key="source_id",
        children=(("article_links", "article_source_id"),),
    ),
    EntitySpec(kind=KIND_SCHEDULES, table="schedules", key="source_id"),
    EntitySpec(kind=KIND_TAGS, table="tags", key="name"),
    EntitySpec(kind=KIND_SERIES, table="series", key="series_key"),
)

SPECS_BY_KIND: dict[str, EntitySpec] = {spec.kind: spec for spec in ENTITY_SPECS}

#: 不参与指纹的列。只放「同一个内容每次导出都会变」的时间戳——
#: `schedules.source_updated_at` 在首站映射的是源库 `last_synced_at`，
#: 每跑一次就刷新一次；纳入指纹会让全部档期永远「有变更」，把真信号淹掉。
#:
#: 注意这里**不是**「随便忽略一列」的逃生门：列进这里就意味着该列的变化
#: 永远不会被感知。新增前先确认它确实不代表内容。
VOLATILE_COLUMNS: dict[str, frozenset[str]] = {
    "schedules": frozenset({"source_updated_at"}),
}


def _quote(name: str) -> str:
    """SQLite 标识符转义。表/列名来自我们自己的 DDL，仍按规矩转义。"""
    return '"' + name.replace('"', '""') + '"'


def _columns(conn: sqlite3.Connection, table: str) -> list[str]:
    """按 DDL 顺序取列名，并剔除不参与指纹的列。

    用 `PRAGMA table_info` 而不是写死列清单：数据集版本升级加列时，
    新列自动进入指纹，否则「只改了新列」的变更会被静默漏掉。
    """
    rows = conn.execute(f"PRAGMA table_info({_quote(table)})").fetchall()
    if not rows:
        raise KeyError(f"数据集里没有表 {table!r}")
    skip = VOLATILE_COLUMNS.get(table, frozenset())
    return [str(row[1]) for row in rows if str(row[1]) not in skip]


def _payload(values: Sequence[object]) -> str:
    """一行的规范化表示：保持列序、紧凑分隔符。

    不做排序或类型归一——同一列在同一个数据集里类型稳定（导出器已强转），
    但**行的顺序**不稳定（多行没有主键，SQLite 的返回顺序不保证），
    所以子表的行要在外部先排序再拼接。
    """
    return json.dumps(list(values), ensure_ascii=False, separators=(",", ":"), default=str)


def _digest(parts: Iterable[str]) -> str:
    """把一个实体的所有组成部分折成一个短指纹。

    用 `\\x1f`（单元分隔符）隔开，避免 `["ab","c"]` 与 `["a","bc"]` 拼出同一个串。
    """
    h = hashlib.sha256()
    for part in parts:
        h.update(part.encode("utf-8"))
        h.update(b"\x1f")
    return h.hexdigest()[:16]


@dataclass
class Manifest:
    """一次快照的指纹全集。`entries[kind][key] = digest`。"""

    entries: dict[str, dict[str, str]] = field(default_factory=dict)
    #: 子表里指向了不存在实体的行数（按表统计）。正常应为空——
    #: 非空说明映射的 join 写漏了，或源库有孤儿行。
    orphans: dict[str, int] = field(default_factory=dict)

    def counts(self) -> dict[str, int]:
        return {kind: len(rows) for kind, rows in self.entries.items()}

    @property
    def total(self) -> int:
        return sum(len(rows) for rows in self.entries.values())


def build_manifest(
    dataset_path: str | Path,
    *,
    kinds: Sequence[str] | None = None,
) -> Manifest:
    """扫描一遍数据集，算出每个实体的指纹。

    复杂度是 O(行数)：每张表只读一次，子表行按外键归到对应实体后排序。
    """
    wanted = tuple(kinds) if kinds else tuple(spec.kind for spec in ENTITY_SPECS)
    unknown = [k for k in wanted if k not in SPECS_BY_KIND]
    if unknown:
        raise KeyError(f"未知实体类型: {', '.join(unknown)}")

    manifest = Manifest()
    conn = sqlite3.connect(str(dataset_path))
    try:
        for spec in ENTITY_SPECS:
            if spec.kind not in wanted:
                continue
            manifest.entries[spec.kind] = _digest_kind(conn, spec, manifest.orphans)
    finally:
        conn.close()
    return manifest


def _digest_kind(
    conn: sqlite3.Connection, spec: EntitySpec, orphans: dict[str, int]
) -> dict[str, str]:
    key_cols = _columns(conn, spec.table)
    if spec.key not in key_cols:
        raise KeyError(f"{spec.table} 缺少键列 {spec.key!r}")

    key_index = key_cols.index(spec.key)
    # 每个实体的组成部分：先主表行，再各子表行（子表内按内容排序）
    parts: dict[str, list[str]] = {}
    for row in conn.execute(
        f"SELECT {', '.join(_quote(c) for c in key_cols)} FROM {_quote(spec.table)}"
    ):
        parts[str(row[key_index])] = [_payload(row)]

    for table, fk in spec.children:
        child_cols = _columns(conn, table)
        if fk not in child_cols:
            # 数据集版本不同可能还没这张表/列；缺了就不算，不炸整个导出
            continue
        fk_index = child_cols.index(fk)
        # 子表没有主键，SQLite 返回顺序不保证，所以必须先全取再按内容排序，
        # 否则同一份数据两次导出的指纹会不一样（假变更）。
        buckets: dict[str, list[str]] = {}
        for row in conn.execute(
            f"SELECT {', '.join(_quote(c) for c in child_cols)} FROM {_quote(table)}"
        ):
            fk_value = str(row[fk_index])
            buckets.setdefault(fk_value, []).append(_payload(row))
        for fk_value, payloads in buckets.items():
            target = parts.get(fk_value)
            if target is None:
                orphans[table] = orphans.get(table, 0) + len(payloads)
                continue
            payloads.sort()
            target.extend(payloads)

    return {key: _digest(items) for key, items in parts.items()}


@dataclass(frozen=True)
class KindDiff:
    """一类实体的差异。三个集合都是稳定排序的键名，便于比对与展示。"""

    kind: str
    added: tuple[str, ...] = ()
    changed: tuple[str, ...] = ()
    deleted: tuple[str, ...] = ()

    @property
    def is_empty(self) -> bool:
        return not (self.added or self.changed or self.deleted)

    def to_dict(self) -> dict[str, object]:
        return {
            "kind": self.kind,
            "added": len(self.added),
            "changed": len(self.changed),
            "deleted": len(self.deleted),
        }


@dataclass
class DiffReport:
    kinds: dict[str, KindDiff] = field(default_factory=dict)

    @property
    def is_empty(self) -> bool:
        return all(diff.is_empty for diff in self.kinds.values())

    @property
    def added(self) -> int:
        return sum(len(d.added) for d in self.kinds.values())

    @property
    def changed(self) -> int:
        return sum(len(d.changed) for d in self.kinds.values())

    @property
    def deleted(self) -> int:
        return sum(len(d.deleted) for d in self.kinds.values())

    def to_dict(self) -> dict[str, object]:
        return {
            "added": self.added,
            "changed": self.changed,
            "deleted": self.deleted,
            "kinds": {kind: diff.to_dict() for kind, diff in self.kinds.items()},
        }


def diff_manifests(previous: Manifest, current: Manifest) -> DiffReport:
    """对比两份指纹。

    `previous` 为空（首次跑）时全部算新增——这是对的：那确实是我们第一次拿到这些数据。
    """
    report = DiffReport()
    for kind in sorted(set(previous.entries) | set(current.entries)):
        before = previous.entries.get(kind, {})
        after = current.entries.get(kind, {})
        added = tuple(sorted(set(after) - set(before)))
        deleted = tuple(sorted(set(before) - set(after)))
        changed = tuple(
            sorted(key for key in set(before) & set(after) if before[key] != after[key])
        )
        report.kinds[kind] = KindDiff(
            kind=kind, added=added, changed=changed, deleted=deleted
        )
    return report


_MANIFEST_DDL = """
PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;
CREATE TABLE manifest_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE entity_digest (
    kind   TEXT NOT NULL,
    key    TEXT NOT NULL,
    digest TEXT NOT NULL,
    PRIMARY KEY (kind, key)
);
"""


def save_manifest(
    path: str | Path,
    manifest: Manifest,
    *,
    source_id: str,
    dataset_path: str | Path,
    dataset_fingerprint: str | None = None,
    generated_at: str | None = None,
) -> Path:
    """原子写入 manifest。

    先写同目录 `.tmp` 再 `os.replace`：中途失败时旧文件保持完好——
    半份 manifest 会让下一轮把所有内容误判成「新增」。
    """
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=str(target.parent), suffix=".tmp")
    os.close(fd)
    tmp = Path(tmp_name)
    try:
        conn = sqlite3.connect(str(tmp))
        try:
            conn.executescript(_MANIFEST_DDL)
            meta = {
                "manifest_version": MANIFEST_VERSION,
                "source_id": source_id,
                "dataset_path": str(dataset_path),
                "dataset_fingerprint": dataset_fingerprint or "",
                "generated_at": generated_at or "",
                "counts_json": json.dumps(manifest.counts(), ensure_ascii=False),
                "orphans_json": json.dumps(manifest.orphans, ensure_ascii=False),
            }
            conn.executemany(
                "INSERT INTO manifest_meta(key, value) VALUES (?, ?)", sorted(meta.items())
            )
            conn.executemany(
                "INSERT INTO entity_digest(kind, key, digest) VALUES (?, ?, ?)",
                [
                    (kind, key, digest)
                    for kind, rows in manifest.entries.items()
                    for key, digest in rows.items()
                ],
            )
            conn.commit()
        finally:
            conn.close()
        os.replace(tmp, target)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise
    return target


def load_manifest(path: str | Path) -> Manifest:
    """读回一份 manifest。文件不存在时返回空 Manifest（等价于「首次」）。"""
    source = Path(path)
    if not source.exists():
        return Manifest()
    conn = sqlite3.connect(str(source))
    try:
        manifest = Manifest()
        for kind, key, digest in conn.execute(
            "SELECT kind, key, digest FROM entity_digest ORDER BY kind, key"
        ):
            manifest.entries.setdefault(str(kind), {})[str(key)] = str(digest)
        return manifest
    finally:
        conn.close()


def read_manifest_meta(path: str | Path) -> dict[str, str]:
    """读 manifest 的元信息（版本、来源、生成时间、行数）。"""
    source = Path(path)
    if not source.exists():
        return {}
    conn = sqlite3.connect(str(source))
    try:
        return {
            str(k): str(v)
            for k, v in conn.execute("SELECT key, value FROM manifest_meta ORDER BY key")
        }
    finally:
        conn.close()


def is_compatible(path: str | Path) -> bool:
    """旧 manifest 的格式版本是否还能直接比对。

    版本不一致时宁可当成「首次」也不要硬比：格式变了还硬比，会把
    「格式升级」误报成几十万条变更。
    """
    meta = read_manifest_meta(path)
    return bool(meta) and meta.get("manifest_version") == MANIFEST_VERSION
