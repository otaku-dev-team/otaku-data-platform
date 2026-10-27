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
REASON_INVALID_WEEKDAY = "INVALID_WEEKDAY"
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
    # ---- 富字段（档 A，2026-10-28 契约扩入）----
    title_original: str | None = None
    aliases: list[str] | None = None
    media: str | None = None
    episodes: int | None = None
    # ---- 关联数组（档 B，2026-10-28 契约扩入）----
    staff: list[dict[str, Any]] | None = None
    characters: list[dict[str, Any]] | None = None
    studios: list[str] | None = None

    @property
    def source_id(self) -> str:
        return self.source_record.source_id

    def to_payload(self) -> dict[str, Any]:
        """转成导入接口（接口②）的 JSON 体。

        输出契约约定的 16 个字段，字段名与契约、openapi.yaml 完全一致。
        空值一律传 null，不传空字符串。

        `release_year` 自 2026-10-22 起纳入（此前「第一阶段不纳入」）。
        来源站实测非空率 95.9%，数据可用，见 docs/站点能力差距清单.md。

        `source_url` 用于客户端「在来源站查看原页」的回流入口：
        Otaku 为 `/contents/{id}` 人读页，Bangumi 为 `https://bgm.tv/subject/{id}`。
        无法可靠确定原页时传 null，不猜测生成（契约第 2.1 节）。

        **富字段与关联数组全部是「None = 不覆盖」语义**：这些字段只有数据集通道
        （直读客户库）拿得到，站点 REST 通道拿不到。所以站点适配器构造 items 时
        它们保持 None，后端据此不动库里已有的值——若把 None 当「清空」，一次
        常规站点同步就会把数据集通道导进来的 Staff / 原名全抹掉。

        None 的字段**直接不出现在载荷里**（不是发 null）：契约里「省略」与「null」
        同义，而站点通道全量 1.8 万条、每批 500 条，平白多 7 个 null 键只是白占
        带宽。数据集通道真有值时才带上。

        `source_updated_at` 仅作本地记录，不提交。
        """
        payload: dict[str, Any] = {
            "source_id": self.source_record.source_id,
            "work_type": self.work_type,
            "title": self.title,
            "summary": self.summary,
            "cover_url": self.cover_url,
            "release_year": self.release_year,
            "tags": self.tags,
            "main_rating": self.main_rating.to_payload() if self.main_rating else None,
            "source_url": self.source_record.source_url,
        }
        for key in (
            "title_original",
            "aliases",
            "media",
            "episodes",
            "staff",
            "characters",
            "studios",
        ):
            value = getattr(self, key)
            if value is not None:
                payload[key] = value
        return payload


@dataclass
class ScheduleItem:
    """待导入的一条新番档期（来源站 /api/schedule）。

    与 WorkItem 平行：同一套 SourceRecord / fetched_at 口径，字段按站点档期
    结构来。work_tags 在同步侧就把斜杠字符串拆成数组——后端契约收数组，
    让两边都不猜对方的格式。
    """

    source_record: SourceRecord
    season_code: str | None = None
    title_main: str | None = None
    title_cn: str | None = None
    title_jp: str | None = None
    weekday: int | None = None
    broadcast_time: str | None = None
    broadcast_note: str | None = None
    work_type: str | None = None
    work_tags: list[str] | None = None
    image_url: str | None = None
    platforms: list[dict] | None = None
    source_url: str | None = None
    content_id: str | None = None
    source_updated_at: str | None = None

    @property
    def source_id(self) -> str:
        return self.source_record.source_id

    def to_payload(self) -> dict[str, Any]:
        """转成内部导入接口（档期）的 JSON 体。

        字段名与后端 ScheduleImportRequest 一致。空值一律传 null。
        `source_updated_at` 取自站点 last_synced_at，同步侧转成 ISO-8601
        （站点给的是 "2026-10-20 06:01:50" 空格分隔、无时区，按 UTC 处理）。
        """
        return {
            "source_id": self.source_record.source_id,
            "season_code": self.season_code,
            "title_main": self.title_main,
            "title_cn": self.title_cn,
            "title_jp": self.title_jp,
            "weekday": self.weekday,
            "broadcast_time": self.broadcast_time,
            "broadcast_note": self.broadcast_note,
            "work_type": self.work_type,
            "work_tags": self.work_tags,
            "image_url": self.image_url,
            "platforms": self.platforms,
            "source_url": self.source_url,
            "content_id": self.content_id,
            "source_updated_at": self.source_updated_at,
        }


@dataclass
class ArticleItem:
    """待导入的一条资讯（来源站 /articles 与 /articles/{id}）。

    与 WorkItem / ScheduleItem 平行：同一套 SourceRecord / fetched_at 口径。

    **两个 source_url 别混**：
    - `source_record.source_url` 是站点上的**资讯页**（/articles/339），
      用于排障时人工核对；
    - `source_url` 是**原文链接**（如 ln-news.com），只有详情页给得出，
      客户端用它跳回来源站（项目章程 G3「用户不被困在平台内」）。

    正文与原文链接来自详情页，列表页没有：抓详情失败时这条资讯照样入库，
    只是 body / source_url / source_name 为 None——标题、摘要、时间、
    封面仍然够列表页用，不该因为一个详情页抓不到就整条丢掉。
    """

    source_record: SourceRecord
    title: str | None = None
    summary: str | None = None
    body: str | None = None
    category: str | None = None
    published_at: str | None = None
    source_name: str | None = None
    source_url: str | None = None
    cover_url: str | None = None
    tags: list[str] | None = None
    related_work_ids: list[str] | None = None

    @property
    def source_id(self) -> str:
        return self.source_record.source_id

    def to_payload(self) -> dict[str, Any]:
        """转成内部导入接口（资讯）的 JSON 体。

        字段名与后端 ArticleImportRequest 一致，空值一律传 null。
        """
        return {
            "source_id": self.source_record.source_id,
            "title": self.title,
            "summary": self.summary,
            "body": self.body,
            "category": self.category,
            "published_at": self.published_at,
            "source_name": self.source_name,
            "source_url": self.source_url,
            "cover_url": self.cover_url,
            "tags": self.tags,
            "related_work_ids": self.related_work_ids,
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
