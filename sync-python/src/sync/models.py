"""与 docs/data-contract.md 对应的数据结构。"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

from .config import RATING_SCALE, SOURCE_NAME

VALID_WORK_TYPES = ("anime", "comic", "game", "novel")

RESULT_INSERTED = "inserted"
RESULT_UPDATED = "updated"
RESULT_UNCHANGED = "unchanged"
RESULT_REJECTED = "rejected"
VALID_RESULTS = (RESULT_INSERTED, RESULT_UPDATED, RESULT_UNCHANGED, RESULT_REJECTED)

REASON_INVALID_TYPE = "INVALID_TYPE"
REASON_TITLE_REQUIRED = "TITLE_REQUIRED"
REASON_RATING_OUT_OF_SCALE = "RATING_OUT_OF_SCALE"
REASON_INTERNAL_ERROR = "INTERNAL_ERROR"


def utc_now() -> str:
    """RFC 3339 UTC 时间戳字符串。"""
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


@dataclass
class SourceRecord:
    """来源映射。唯一约束为 (source, source_id)。"""

    source_id: str
    source_url: str | None = None
    fetched_at: str = field(default_factory=utc_now)
    source_updated_at: str | None = None
    source: str = SOURCE_NAME


@dataclass
class Rating:
    """来源评分。缺失时整体为 None，绝不按 0 分处理。"""

    value: float
    scale: str = RATING_SCALE
    source: str = SOURCE_NAME

    def to_payload(self) -> dict[str, Any]:
        return {"value": self.value, "scale": self.scale, "source": self.source}


@dataclass
class WorkItem:
    """待导入的一条作品数据。"""

    source_record: SourceRecord
    work_type: str
    title: str
    summary: str | None = None
    main_rating: Rating | None = None
    cover_url: str | None = None
    release_year: int | None = None
    tags: list[str] | None = None

    @property
    def source_id(self) -> str:
        return self.source_record.source_id

    def to_payload(self) -> dict[str, Any]:
        """转成导入接口（接口②）的 JSON 体。

        只输出契约约定的 7 个字段，字段名与契约、openapi.yaml 完全一致。
        `release_year`（第一阶段不纳入）、`source_url`、`source_updated_at`
        仅作本地记录，不提交。空值一律传 null，不传空字符串。
        """
        return {
            "source_id": self.source_record.source_id,
            "work_type": self.work_type,
            "title": self.title,
            "summary": self.summary,
            "cover_url": self.cover_url,
            "tags": self.tags,
            "main_rating": self.main_rating.to_payload() if self.main_rating else None,
        }


@dataclass
class ItemResult:
    """单条导入结果。"""

    source_id: str
    result: str
    work_id: str | None = None
    reason_code: str | None = None
    message: str | None = None

    @classmethod
    def from_payload(cls, payload: dict[str, Any]) -> "ItemResult":
        return cls(
            source_id=str(payload.get("source_id", "")),
            result=payload.get("result", RESULT_REJECTED),
            work_id=payload.get("work_id"),
            reason_code=payload.get("code") or payload.get("reason_code"),
            message=payload.get("message"),
        )


@dataclass
class BatchResult:
    """一个批次的导入结果。"""

    batch_id: str
    counts: dict[str, int]
    errors: list[ItemResult] = field(default_factory=list)
    started_at: str | None = None
    finished_at: str | None = None
    delivered: bool = True

    @classmethod
    def from_payload(cls, payload: dict[str, Any]) -> "BatchResult":
        counts = payload.get("counts") or {}
        return cls(
            batch_id=payload.get("batch_id", ""),
            counts={k: int(counts.get(k, 0)) for k in
                    ("inserted", "updated", "unchanged", "rejected")},
            errors=[ItemResult.from_payload(e) for e in payload.get("errors") or []],
            started_at=payload.get("started_at"),
            finished_at=payload.get("finished_at"),
        )

    @property
    def submitted(self) -> int:
        return sum(self.counts.values())
