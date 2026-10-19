"""来源适配：现有 Otaku 网站的 JSON API。

实测结论（2026-10-19，见 docs/data-contract.md 第 1 节）：
- `/api/contents` 忽略 page / page_size，**一次返回全量**
- 仅返回 id / title / type / summary / rating 五个字段
- 不提供封面、年份、标签、来源更新时间 -> 映射时全部置为 None
- 标题会重复：同类型 55 组、跨类型 341 组，因此**只认 (source, source_id)**
"""

from __future__ import annotations

from typing import Any, Iterable

import httpx

from .cleaning import clean_rating, clean_summary, clean_title
from .models import SourceRecord, WorkItem


def unwrap(payload: Any) -> list[dict[str, Any]]:
    """兼容列表与 {items: [...]} 两种返回形态。"""
    if isinstance(payload, dict):
        items = payload.get("items")
        return list(items or [])
    return list(payload or [])


class OtakuSiteSource:
    """读取现有网站的作品列表。"""

    def __init__(
        self,
        base_url: str,
        client: httpx.Client | None = None,
        timeout: float = 30.0,
        user_agent: str = "otaku-data-platform-sync/0.1.0",
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self._client = client or httpx.Client(
            timeout=timeout, headers={"User-Agent": user_agent}
        )
        self._owns_client = client is None

    def close(self) -> None:
        if self._owns_client:
            self._client.close()

    def __enter__(self) -> "OtakuSiteSource":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def fetch_raw(self, work_type: str) -> list[dict[str, Any]]:
        """拉取某一类型的全部记录。列表接口不分页，因此只发一次请求。"""
        resp = self._client.get(
            f"{self.base_url}/api/contents", params={"type": work_type}
        )
        resp.raise_for_status()
        return unwrap(resp.json())

    def search_raw(self, keyword: str, page: int = 1, page_size: int = 20) -> dict[str, Any]:
        """搜索接口，支持真正的分页。当前同步流程未使用，保留给后续增量同步。"""
        resp = self._client.get(
            f"{self.base_url}/api/contents/search",
            params={"q": keyword, "page": page, "page_size": page_size},
        )
        resp.raise_for_status()
        return resp.json()

    def to_work_item(self, raw: dict[str, Any], fetched_at: str) -> WorkItem:
        """把来源记录映射成导入条目。id 统一转字符串，避免数值歧义。"""
        source_id = str(raw.get("id"))
        return WorkItem(
            source_record=SourceRecord(
                source_id=source_id,
                source_url=f"{self.base_url}/api/contents/{source_id}",
                fetched_at=fetched_at,
                source_updated_at=None,
            ),
            work_type=str(raw.get("type") or ""),
            title=clean_title(raw.get("title")),
            summary=clean_summary(raw.get("summary")),
            rating=clean_rating(raw.get("rating")),
            cover_url=None,
            release_year=None,
            tags=None,
        )

    def fetch(self, work_type: str, fetched_at: str) -> list[WorkItem]:
        return [self.to_work_item(r, fetched_at) for r in self.fetch_raw(work_type)]

    def fetch_many(
        self, work_types: Iterable[str], fetched_at: str
    ) -> list[WorkItem]:
        items: list[WorkItem] = []
        for work_type in work_types:
            items.extend(self.fetch(work_type, fetched_at))
        return items
