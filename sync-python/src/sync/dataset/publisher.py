"""把标准数据集提交到后端（数据集 → 接口②）。

这一层很薄，但有两个不能含糊的地方，其余都是搬运。

## 一、`backend_source` 决定「更新」还是「新增」

后端唯一键是 `(source, source_id)`。数据集里的 `meta.source_id`（例如 `otaku`）
是我们给**数据集**起的标签，不是后端行上的 `source`；后端现存行用的是站点自身的
来源标识（`SOURCE_NAME`）。两者只要不一致，同一批作品就会被当成**新作品插入一遍**
——1.8 万条目录变 3.6 万条，而且列表页看不出来是重复，只看到"两个一样的"。

所以这里不用 `meta.source_id` 当 `source`，而是显式要一个 `backend_source`，
并在报告里原样回显。选错了必须一眼能看见。

## 二、`batch_id` 由内容算出，因此「重跑 = 续跑」

`batch_id` 是后端幂等键，同一 id 重复提交返回首次结果、不重复入库。这里按
「批次序号 + 该批条目内容的 sha256」生成，于是：

- 中途断了，重跑同一份数据集 → 每批 id 与上次一致 → 已成功的批直接空转，
  从断点继续，不需要本地状态文件（也就不存在"状态文件丢了不知道从哪续"）；
- 数据真的变了（重导过）→ 内容哈希变 → 新 id → 正常 upsert，不会被旧 id 吞掉。

反面做法是「用固定序号当 id」：那样数据更新后重跑会静默什么都不做，
是比崩溃更糟的失败方式。

## 本版范围

只发 `works`。资讯与档期仍走原通道（`--articles` / `--schedule`），它们各有
自己的端点与字段语义（正文 HTML、platforms JSON），混进这一层只会让
「哪来的数据」变模糊。要把它们也改成从数据集发，是加同构的 publisher，
不是改这里。
"""

from __future__ import annotations

import hashlib
import json
import sqlite3
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator, Sequence

from ..cleaning import clean_cover_url
from ..config import RATING_SCALE, SOURCE_NAME
from ..importer import ImportDeliveryError, InternalImportError
from ..models import (
    VALID_WORK_TYPES,
    BatchResult,
    ItemResult,
    Rating,
    SourceRecord,
    WorkItem,
)
from .exporter import assert_compatible, read_meta

#: 契约硬上限（超出返回 413 BATCH_TOO_LARGE，Python 侧必须自己拆批）。
CHUNK_LIMIT = 500

#: 报告里最多保留多少条后端拒收明细。全留会让报告变成几 MB 的日志。
MAX_ERRORS_KEPT = 200

#: 预演时落盘的样例条数。全量 1.8 万条写出来没人看，也浪费磁盘。
SAMPLE_ITEMS = 20


@dataclass
class BatchSummary:
    """一个批次的提交结果（或预演时"将会提交"的形状）。"""

    batch_id: str
    items: int
    counts: dict[str, int] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {"batch_id": self.batch_id, "items": self.items, "counts": self.counts}


@dataclass
class PublishReport:
    dataset_path: str
    backend_source: str
    fetched_at: str
    dry_run: bool
    elapsed_seconds: float = 0.0
    generated_at: str = field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat(timespec="seconds")
    )
    works_scanned: int = 0
    items_built: int = 0
    batches: list[BatchSummary] = field(default_factory=list)
    counts: dict[str, int] = field(default_factory=dict)
    errors: list[ItemResult] = field(default_factory=list)
    errors_dropped: int = 0
    skipped_invalid_type: int = 0
    skipped_samples: list[dict[str, Any]] = field(default_factory=list)
    covers_absolute: int = 0
    covers_resolved: int = 0
    covers_dropped: int = 0
    covers_empty: int = 0
    aborted: str | None = None
    warnings: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return self.aborted is None

    def to_dict(self) -> dict[str, Any]:
        return {
            "dataset_path": self.dataset_path,
            "backend_source": self.backend_source,
            "fetched_at": self.fetched_at,
            "dry_run": self.dry_run,
            "generated_at": self.generated_at,
            "elapsed_seconds": round(self.elapsed_seconds, 2),
            "works_scanned": self.works_scanned,
            "items_built": self.items_built,
            "batch_count": len(self.batches),
            "batches": [b.to_dict() for b in self.batches],
            "counts": self.counts,
            "rejected": self.counts.get("rejected", 0),
            "errors": [
                {
                    "source_id": e.source_id,
                    "code": e.reason_code,
                    "message": e.message,
                }
                for e in self.errors
            ],
            "errors_dropped": self.errors_dropped,
            "skipped_invalid_type": self.skipped_invalid_type,
            "skipped_samples": self.skipped_samples,
            "covers": {
                "absolute": self.covers_absolute,
                "resolved_from_relative": self.covers_resolved,
                "dropped": self.covers_dropped,
                "empty": self.covers_empty,
            },
            "aborted": self.aborted,
            "warnings": self.warnings,
        }


# ---------------------------------------------------------------- 批次号


def _content_digest(payloads: Sequence[dict[str, Any]]) -> str:
    """批次内容的稳定哈希。sort_keys 保证同一批数据每次算出同一个值。

    注意用 `ensure_ascii=False`：转义与否会改变字节，但两边一致即可；
    取 False 是为了让哈希对"中文被写成 \\uXXXX 还是原字"不敏感——数据集里
    全是中文标题，这个选择直接决定断点续跑会不会真的命中。
    """
    blob = json.dumps(
        payloads, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    )
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def make_batch_id(kind: str, index: int, payloads: Sequence[dict[str, Any]]) -> str:
    """批次号 = 种类 + 序号 + 内容哈希前 16 位，总长受后端 VARCHAR(128) 限制。"""
    return f"ds-{kind}-{index:05d}-{_content_digest(payloads)[:16]}"


# ---------------------------------------------------------------- 读数据集


def _connect(dataset_path: str | Path) -> sqlite3.Connection:
    conn = sqlite3.connect(f"file:{Path(dataset_path).as_posix()}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def _tags_for(conn: sqlite3.Connection, ids: Sequence[str]) -> dict[str, list[str]]:
    """一次取整批的标签，不做 N+1。

    **无标签的作品返回空（不返回 `[]`）**：数据集里没有行，既可能是"确实没标签"，
    也可能是"源站没录"，两者在数据集里无法区分。按契约，`[]` 的语义是
    "明确无标签，会清空已有标签"，`null` 是"本次没数据，不覆盖"。既然分不清，
    就选不覆盖——把已有标签误清空是不可逆的内容损失，比少更新一次严重。
    """
    if not ids:
        return {}
    placeholders = ",".join("?" * len(ids))
    rows = conn.execute(
        f'SELECT source_id, name FROM work_tags WHERE source_id IN ({placeholders})'
        f" ORDER BY source_id, name",
        list(ids),
    )
    out: dict[str, list[str]] = {}
    for row in rows:
        out.setdefault(row["source_id"], []).append(row["name"])
    return out


def _staff_for(conn: sqlite3.Connection, ids: Sequence[str]) -> dict[str, list[dict]]:
    """一次取整批的制作人员，不做 N+1。

    与 `_tags_for` 同样的取舍：**没有记录的作品返回空（不返回 `[]`）**。数据集里
    没有行，既可能是"确实没有 Staff"，也可能是"源站没录"，两者分不清；按契约
    `[]` 的意思是"明确没有，清空已有值"，误判就是不可逆的内容损失。

    顺序按数据集里的 `sort_order`：来源侧已经排好了（导演在前、脚本在后），
    重排一次等于替来源决定"谁更重要"。
    """
    if not ids:
        return {}
    placeholders = ",".join("?" * len(ids))
    rows = conn.execute(
        f"SELECT source_id, role, name, person_ref FROM work_credits"
        f" WHERE source_id IN ({placeholders})"
        f" ORDER BY source_id, sort_order, role, name",
        list(ids),
    )
    out: dict[str, list[dict]] = {}
    seen: dict[str, set[tuple]] = {}
    for row in rows:
        entry = {
            "role": row["role"],
            "name": row["name"],
            # 人物实体 id；Staff 侧绝大多数为空（来源是 infobox 文本解析）
            "person_id": row["person_ref"],
        }
        key = (entry["role"], entry["name"], entry["person_id"])
        # 源表没有唯一约束，「同一个人在同一职位出现两次」是真实存在的
        # （跨季合并、数据重复导入都会产生），去重比让客户端去重省事
        if key in seen.setdefault(row["source_id"], set()):
            continue
        seen[row["source_id"]].add(key)
        out.setdefault(row["source_id"], []).append(entry)
    return out


def _characters_for(
    conn: sqlite3.Connection, ids: Sequence[str]
) -> dict[str, list[dict]]:
    """一次取整批的角色与声优。取舍与 `_staff_for` 完全一致。"""
    if not ids:
        return {}
    placeholders = ",".join("?" * len(ids))
    rows = conn.execute(
        f"SELECT source_id, character, actor, relation, person_ref FROM work_cast"
        f" WHERE source_id IN ({placeholders})"
        f" ORDER BY source_id, sort_order, character",
        list(ids),
    )
    out: dict[str, list[dict]] = {}
    seen: dict[str, set[tuple]] = {}
    for row in rows:
        entry = {
            "name": row["character"],
            "actor": row["actor"],
            # 数据集列叫 relation，契约叫 character_type：前者是源表原词，
            # 后者对客户端更有意义（relation 容易被理解成"作品间关系"）
            "character_type": row["relation"],
            "person_id": row["person_ref"],
        }
        key = (entry["name"], entry["actor"], entry["person_id"])
        if key in seen.setdefault(row["source_id"], set()):
            continue
        seen[row["source_id"]].add(key)
        out.setdefault(row["source_id"], []).append(entry)
    return out


def _studios_for(conn: sqlite3.Connection, ids: Sequence[str]) -> dict[str, list[str]]:
    """一次取整批的制作公司。取舍与 `_staff_for` 一致。"""
    if not ids:
        return {}
    placeholders = ",".join("?" * len(ids))
    rows = conn.execute(
        f"SELECT source_id, name FROM work_studios"
        f" WHERE source_id IN ({placeholders})"
        f" ORDER BY source_id, name",
        list(ids),
    )
    out: dict[str, list[str]] = {}
    for row in rows:
        bucket = out.setdefault(row["source_id"], [])
        if row["name"] not in bucket:
            bucket.append(row["name"])
    return out


def _resolve_cover(
    raw: Any, site_base_url: str, report: PublishReport
) -> str | None:
    """把封面地址归一成绝对 URL，同时记账。

    为什么不能原样发：站点 `contents.image_url` 存的是站内相对路径
    （实测 `/covers/cover_x.jpg`），后端封面代理要求带 scheme，收到相对路径
    会直接跳过；更糟的是导入是 upsert —— 它会用这个不可用的地址**覆盖掉**
    之前由站点适配器写好的绝对地址，封面覆盖率先降一大截，而且没有任何报错。

    拿不到 base_url 时返回 None（不覆盖）而不是硬写相对路径：少更新一次
    是可以恢复的，写坏一列地址不是。
    """
    text = "" if raw is None else str(raw).strip()
    if not text:
        report.covers_empty += 1
        return None
    url = clean_cover_url(text, site_base_url)
    if url is None:
        report.covers_dropped += 1
        return None
    if text.startswith(("http://", "https://")):
        report.covers_absolute += 1
    else:
        report.covers_resolved += 1
    return url


def _parse_aliases(raw: Any) -> list[str] | None:
    """数据集里的 `aliases_json`（TEXT）→ 别名数组。

    坏 JSON 不发、返回 None 而不是发空数组：`[]` 的语义是「明确没有别名，清空」，
    解析失败说明我们不知道有没有，退回「不覆盖」才是安全的一侧。
    """
    if not raw:
        return None
    try:
        parsed = json.loads(raw)
    except (TypeError, ValueError):
        return None
    if not isinstance(parsed, list):
        return None
    names = [str(x).strip() for x in parsed if str(x).strip()]
    return names or None


def _to_work_item(
    row: sqlite3.Row,
    *,
    tags: dict[str, list[str]],
    staff: dict[str, list[dict]],
    characters: dict[str, list[dict]],
    studios: dict[str, list[str]],
    backend_source: str,
    site_base_url: str,
    report: PublishReport,
) -> WorkItem:
    """数据集一行 → 接口②的一条（16 字段）。

    **富字段与关联数组一律用 `or None`**：空数组发 `[]` 意味着「明确没有，清空」，
    而数据集里没有行分不清「确实没有」与「源站没录」，所以退回不覆盖。
    见 `_tags_for` / `_staff_for` 的说明。
    """
    value = row["rating_value"]
    scale = row["rating_scale"] or RATING_SCALE
    rating = (
        Rating(value=float(value), scale=scale, source=backend_source)
        if value is not None
        else None
    )
    source_id = row["source_id"]
    return WorkItem(
        source_record=SourceRecord(
            source_id=source_id,
            source_url=row["source_url"],
            source=backend_source,
        ),
        work_type=row["work_type"],
        title=row["title"],
        summary=row["summary"],
        main_rating=rating,
        cover_url=_resolve_cover(row["cover_url"], site_base_url, report),
        release_year=row["release_year"],
        tags=tags.get(source_id) or None,
        title_original=row["title_original"],
        aliases=_parse_aliases(row["aliases_json"]),
        media=row["media"],
        episodes=row["episodes"],
        staff=staff.get(source_id) or None,
        characters=characters.get(source_id) or None,
        studios=studios.get(source_id) or None,
    )


def _iter_chunks(
    conn: sqlite3.Connection,
    chunk_size: int,
    backend_source: str,
    report: PublishReport,
    site_base_url: str = "",
) -> Iterator[list[WorkItem]]:
    """按 source_id 排序分块产出。

    排序不是为了好看：分块必须**稳定**，否则重跑时同一批次的成员变了，
    内容哈希就变，断点续跑会退化成全量重发。按主键排序是唯一不依赖
    插入顺序的稳定办法。

    `limit` 不在这里处理——截断最后一块属于调用方的记账，混进来会让
    "一块满 500 条"这条不变式变得不可推理。
    """
    cur = conn.execute(
        "SELECT source_id, work_type, title, summary, cover_url, release_year,"
        " rating_value, rating_scale, source_url,"
        " title_original, aliases_json, media, episodes"
        " FROM works ORDER BY source_id"
    )
    batch: list[WorkItem] = []
    while True:
        rows = cur.fetchmany(chunk_size)
        if not rows:
            break
        ids: list[str] = []
        kept: list[sqlite3.Row] = []
        for row in rows:
            report.works_scanned += 1
            wtype = row["work_type"]
            # 后端会 INVALID_TYPE 整条拒收。这里提前挡掉，是为了让报告说清
            # "是我们筛掉的"而不是"后端拒了"，两种原因的处置方式不同。
            if wtype not in VALID_WORK_TYPES:
                report.skipped_invalid_type += 1
                if len(report.skipped_samples) < SAMPLE_ITEMS:
                    report.skipped_samples.append(
                        {
                            "source_id": row["source_id"],
                            "work_type": wtype,
                            "reason": "work_type 不在契约四类内",
                        }
                    )
                continue
            ids.append(row["source_id"])
            kept.append(row)

        if kept:
            tags = _tags_for(conn, ids)
            # 关联数组也按批取：18 万条 credits 逐条查会是 1.8 万次往返
            staff = _staff_for(conn, ids)
            characters = _characters_for(conn, ids)
            studios = _studios_for(conn, ids)
            batch.extend(
                _to_work_item(
                    r,
                    tags=tags,
                    staff=staff,
                    characters=characters,
                    studios=studios,
                    backend_source=backend_source,
                    site_base_url=site_base_url,
                    report=report,
                )
                for r in kept
            )

        while len(batch) >= chunk_size:
            chunk = batch[:chunk_size]
            del batch[:chunk_size]
            yield chunk

    if batch:
        yield batch


# ---------------------------------------------------------------- 提交


def publish_dataset(
    dataset_path: str | Path,
    *,
    backend_source: str = SOURCE_NAME,
    site_base_url: str = "",
    chunk_size: int = CHUNK_LIMIT,
    limit: int | None = None,
    apply: bool = False,
    importer: Any | None = None,
    report_path: str | Path | None = None,
    sample_path: str | Path | None = None,
) -> PublishReport:
    """把数据集里的作品提交到后端。默认预演，`apply=True` 才真的发。

    `site_base_url` 用来把站内相对封面路径拼成绝对地址（见 `_resolve_cover`）；
    不传则相对路径一律不发，避免覆盖掉已有封面。

    `importer` 只需提供 `submit_batch(batch_id, items, fetched_at, source)`；
    测试里可以给假对象，不必真起后端。
    """
    started = time.time()
    if chunk_size < 1 or chunk_size > CHUNK_LIMIT:
        raise ValueError(f"chunk_size 必须在 1–{CHUNK_LIMIT} 之间，实际 {chunk_size}")

    # 版本不认识就别往导入流程里塞，否则读出来的列可能是错的
    meta = assert_compatible(dataset_path)
    fetched_at = meta.get("generated_at") or datetime.now(timezone.utc).isoformat(
        timespec="seconds"
    )
    dataset_source_id = meta.get("source_id")

    report = PublishReport(
        dataset_path=str(dataset_path),
        backend_source=backend_source,
        fetched_at=fetched_at,
        dry_run=not apply,
    )
    if dataset_source_id and dataset_source_id != backend_source:
        # 不是错误，但必须说出来：这正是"重复新增"的入口
        report.warnings.append(
            f"数据集标识 source_id={dataset_source_id!r} 与写入后端的 "
            f"backend_source={backend_source!r} 不同。后端唯一键是 "
            f"(source, source_id)，两者不一致会被当成新作品插入，目录会翻倍。"
            f"同一站换了命名的（两边确属同一站、只是标签不同）可忽略；"
            f"否则先确认再提交。"
        )

    if apply and importer is None:
        raise ValueError("apply=True 时必须提供 importer")

    conn = _connect(dataset_path)
    remaining = limit
    try:
        for index, chunk in enumerate(
            _iter_chunks(conn, chunk_size, backend_source, report, site_base_url)
        ):
            if remaining is not None:
                if remaining <= 0:
                    break
                chunk = chunk[:remaining]
                remaining -= len(chunk)
            payloads = [item.to_payload() for item in chunk]
            batch_id = make_batch_id("works", index, payloads)
            report.items_built += len(chunk)

            if not apply:
                report.batches.append(BatchSummary(batch_id=batch_id, items=len(chunk)))
                continue

            try:
                result: BatchResult = importer.submit_batch(
                    batch_id, chunk, fetched_at, source=backend_source
                )
            except (ImportDeliveryError, InternalImportError) as exc:
                # 不继续硬发：认证坏了或网络断了，后面每一批都会同样失败，
                # 而重跑是幂等的，停在这里把已完成的部分记清楚更有用。
                report.aborted = f"{type(exc).__name__}: {exc}"
                break

            report.batches.append(
                BatchSummary(
                    batch_id=batch_id, items=len(chunk), counts=dict(result.counts)
                )
            )
            for key, value in result.counts.items():
                report.counts[key] = report.counts.get(key, 0) + value
            for err in result.errors:
                if len(report.errors) < MAX_ERRORS_KEPT:
                    report.errors.append(err)
                else:
                    report.errors_dropped += 1
    finally:
        conn.close()

    report.elapsed_seconds = time.time() - started
    if report.aborted:
        report.warnings.append(
            "已中止。重跑同一命令即可从断点继续：已成功的批次 batch_id 不变，"
            "后端会返回首次结果，不会重复入库。"
        )
    if not apply and report.items_built:
        report.warnings.append(
            "这是预演，没有向任何后端发请求。确认无误后加 --apply 才真正写入。"
        )
    if report.covers_dropped:
        report.warnings.append(
            f"{report.covers_dropped} 条封面是站内相对路径且没有可用的站点地址，"
            f"已按 null 发送（不覆盖后端已有封面）。要补上请传 --source-base-url"
            f"（或设 OTAKU_SOURCE_BASE_URL）指向站点根地址。"
        )

    if sample_path is not None and not apply:
        _write_sample(
            dataset_path, Path(sample_path), backend_source, chunk_size, site_base_url
        )

    if report_path is not None:
        rp = Path(report_path)
        rp.parent.mkdir(parents=True, exist_ok=True)
        rp.write_text(
            json.dumps(report.to_dict(), ensure_ascii=False, indent=2), encoding="utf-8"
        )
    return report


def _write_sample(
    dataset_path: str | Path,
    out: Path,
    backend_source: str,
    chunk_size: int,
    site_base_url: str = "",
) -> None:
    """预演时落一份真实载荷样例。看一个真实条目，胜过看十行统计。"""
    conn = _connect(dataset_path)
    try:
        builder = PublishReport(
            dataset_path=str(dataset_path),
            backend_source=backend_source,
            fetched_at="",
            dry_run=True,
        )
        first = next(
            _iter_chunks(
                conn, chunk_size, backend_source, builder, site_base_url
            ),
            None,
        )
        sample = [item.to_payload() for item in (first or [])[:SAMPLE_ITEMS]]
    finally:
        conn.close()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(
        json.dumps(
            {"note": f"仅前 {SAMPLE_ITEMS} 条的载荷样例，非全量", "items": sample},
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
