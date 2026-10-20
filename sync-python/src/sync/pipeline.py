"""同步流程编排：拉取 -> 清洗校验 -> 分批 -> 提交 -> 记录结果。

安全重跑的关键在于 batch_id 的确定性：
同一批输入（来源 id 集合相同）生成同一个 batch_id，Java 侧按幂等键返回首次结果，
因此"重复跑一次"不会新增作品（验收 D2）；数据真的变了才会生成新 batch_id 走更新（验收 D3）。
"""

from __future__ import annotations

import hashlib
import json
import os
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any, Iterable, Sequence

from .bangumi import BangumiArchiveSource
from .config import SOURCE_BANGUMI, SOURCE_NAME, SyncConfig
from .importer import ImportDeliveryError, JavaImporter
from .models import (
    REASON_INTERNAL_ERROR,
    ItemResult,
    RESULT_REJECTED,
    WorkItem,
    utc_now,
)
from .source import OtakuSiteSource
from .cleaning import validate


def fingerprint(items: Sequence[WorkItem]) -> str:
    """按来源 id 集合计算指纹，用于生成确定性 batch_id。"""
    digest = hashlib.sha256()
    for source_id in sorted(item.source_id for item in items):
        digest.update(source_id.encode("utf-8"))
        digest.update(b"\x00")
    return digest.hexdigest()[:12]


def build_batch_id(
    items: Sequence[WorkItem],
    work_types: Sequence[str],
    run_at: str,
    source: str = SOURCE_NAME,
) -> str:
    """生成批次标识。来源 id 集合相同即得到相同结果。

    `source` 进到 batch_id 里，避免两个来源在同一个类型、同一天、
    又恰好撞上相同指纹时共用一个批次号。
    """
    day = run_at[:10].replace("-", "")
    types = "-".join(work_types) or "all"
    return f"{source}-{types}-{day}-{fingerprint(items)}"


def chunked(items: Sequence[WorkItem], size: int) -> list[list[WorkItem]]:
    return [list(items[i : i + size]) for i in range(0, len(items), size)]


@dataclass
class RejectedItem:
    source_id: str
    reason_code: str
    message: str


@dataclass
class RunReport:
    """一次同步运行的完整记录，用于追踪与重跑。"""

    started_at: str
    finished_at: str | None = None
    source: str = SOURCE_NAME
    work_types: list[str] = field(default_factory=list)
    fetched: int = 0
    accepted: int = 0
    rejected: int = 0
    dry_run: bool = False
    batches: list[dict[str, Any]] = field(default_factory=list)
    rejected_items: list[RejectedItem] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        data = asdict(self)
        data["rejected_items"] = [asdict(r) for r in self.rejected_items]
        return data


def _validate(items: Iterable[WorkItem]) -> tuple[list[WorkItem], list[RejectedItem]]:
    accepted: list[WorkItem] = []
    rejected: list[RejectedItem] = []
    for item in items:
        problems = validate(item)
        if problems:
            for code, message in problems:
                rejected.append(
                    RejectedItem(item.source_id, code, message)
                )
        else:
            accepted.append(item)
    return accepted, rejected


def _write_json(path: str, data: Any) -> str:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    return path


def _fetch_items(
    config: SyncConfig,
    types: Sequence[str],
    started: str,
    limit: int | None,
) -> list[WorkItem]:
    """按配置的来源取数据。

    档案来源流式读本地 zip；站点来源走在线 JSON API。
    两条路径都产出 `WorkItem` 列表，后续清洗、分批、提交完全共用。
    """
    if config.source == SOURCE_BANGUMI:
        with BangumiArchiveSource(config.archive_path or "") as source:
            if config.sample_method == "uniform" and limit is not None:
                return source.fetch_sample(types, started, limit)
            return source.fetch_many(types, started, limit=limit)

    with OtakuSiteSource(
        config.source_base_url,
        timeout=config.timeout_seconds,
        user_agent=config.user_agent,
        page_size=config.source_page_size,
        request_interval_seconds=config.request_interval_seconds,
        max_pages=config.max_pages,
    ) as source:
        items = source.fetch_many(types, started)
    return items[:limit] if limit is not None else items


def run(
    config: SyncConfig,
    work_types: Sequence[str] | None = None,
    limit: int | None = None,
    dry_run: bool = False,
    output_dir: str | None = None,
) -> RunReport:
    """执行一次同步。dry_run=True 时不联系 Java，只落盘将要发送的载荷。"""
    types = list(work_types or config.work_types)
    started = utc_now()
    out_dir = output_dir or config.output_dir

    raw_items = _fetch_items(config, types, started, limit)

    accepted, rejected = _validate(raw_items)
    report = RunReport(
        started_at=started,
        source=config.source,
        work_types=types,
        fetched=len(raw_items),
        accepted=len(accepted),
        rejected=len(rejected),
        dry_run=dry_run,
        rejected_items=rejected,
    )

    if not accepted:
        report.finished_at = utc_now()
        return report

    importer: JavaImporter | None = None
    if not dry_run:
        importer = JavaImporter(
            config.java_base_url,
            token=config.internal_token,
            timeout=config.timeout_seconds,
            max_attempts=config.max_attempts,
            backoff_seconds=config.backoff_seconds,
        )

    try:
        for batch_items in chunked(accepted, max(1, config.batch_size)):
            batch_id = build_batch_id(batch_items, types, started, config.source)
            payload = {
                "batch_id": batch_id,
                "source": config.source,
                "fetched_at": started,
                "items": [item.to_payload() for item in batch_items],
            }
            entry: dict[str, Any] = {"batch_id": batch_id, "size": len(batch_items)}

            if dry_run:
                entry["payload_path"] = _write_json(
                    os.path.join(out_dir, f"batch-{batch_id}.json"), payload
                )
                entry["delivered"] = False
            else:
                assert importer is not None
                try:
                    result = importer.submit_batch(
                        batch_id, batch_items, started, config.source
                    )
                    entry.update(
                        delivered=True,
                        counts=result.counts,
                        errors=[
                            asdict(e)
                            for e in result.errors
                            if e.result == RESULT_REJECTED
                        ],
                    )
                except (ImportDeliveryError, RuntimeError) as exc:
                    entry.update(
                        delivered=False,
                        error=str(exc),
                        reason_code=REASON_INTERNAL_ERROR,
                        failed_source_ids=[i.source_id for i in batch_items],
                    )
            report.batches.append(entry)
    finally:
        if importer is not None:
            importer.close()

    report.finished_at = utc_now()
    _write_json(
        os.path.join(out_dir, f"run-{started.replace(':', '').replace('+', 'Z')}.json"),
        report.to_dict(),
    )
    return report


def summarize(report: RunReport) -> str:
    """给终端看的一行摘要。"""
    delivered = sum(1 for b in report.batches if b.get("delivered"))
    counts: dict[str, int] = {}
    for batch in report.batches:
        for key, value in (batch.get("counts") or {}).items():
            counts[key] = counts.get(key, 0) + int(value)
    parts = [
        f"抓取 {report.fetched}",
        f"通过校验 {report.accepted}",
        f"拒绝 {report.rejected}",
        f"批次 {len(report.batches)}（已送达 {delivered}）",
    ]
    if counts:
        parts.append(
            "入库 " + " ".join(f"{k}={v}" for k, v in sorted(counts.items()))
        )
    mode = "dry-run" if report.dry_run else "正式提交"
    return f"[{mode}] " + "，".join(parts)
