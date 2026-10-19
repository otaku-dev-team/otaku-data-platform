"""来源适配：现有 Otaku 网站的 JSON API。

实测结论（2026-10-20 站主升级接口后复核，见 docs/legacy-site-capability.md）：
- `/api/contents` 支持**可选分页** `?page=1&page_size=200`；不传分页参数才是老的全量行为
  （全量现在约 11.6 MB / 25 秒，站主要求必须改用分页）
- 列表与详情均返回 id / title / type / summary / rating + cover_url / tags / year / bangumi_id
- `cover_url` 为站内**相对路径**，须用配置的 base_url 拼成绝对地址
- `cover_{N}.jpg` 的 N 是 bangumi_id，不是 content_id；`cover_url` 已拼好，无需自行映射
- `year` 约 98.5% 为空，是来源已知的数据缺口，不可依赖
- 标题会重复：同类型 55 组、跨类型 341 组，因此**只认 (source, source_id)**

限流口径（站主给定，必须遵守）：page_size <= 200、并发 <= 2、1-2 req/s、每天 <= 5 万请求。
本模块串行拉取，只需控制请求间隔。
"""

from __future__ import annotations

import time
from typing import Any, Iterable

import httpx

from .cleaning import (
    clean_cover_url,
    clean_rating,
    clean_summary,
    clean_tags,
    clean_title,
    clean_year,
)
from .config import (
    DEFAULT_MAX_PAGES,
    DEFAULT_PAGE_SIZE,
    DEFAULT_REQUEST_INTERVAL_SECONDS,
)
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
        page_size: int = DEFAULT_PAGE_SIZE,
        request_interval_seconds: float = DEFAULT_REQUEST_INTERVAL_SECONDS,
        max_pages: int = DEFAULT_MAX_PAGES,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.page_size = max(1, page_size)
        self.request_interval_seconds = max(0.0, request_interval_seconds)
        self.max_pages = max(1, max_pages)
        self._client = client or httpx.Client(
            timeout=timeout, headers={"User-Agent": user_agent}
        )
        self._owns_client = client is None
        self._last_request_at = 0.0

    def close(self) -> None:
        if self._owns_client:
            self._client.close()

    def __enter__(self) -> "OtakuSiteSource":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def _throttle(self) -> None:
        """把请求速率压在来源方要求的 1-2 req/s 区间内。"""
        if self.request_interval_seconds <= 0:
            return
        elapsed = time.monotonic() - self._last_request_at
        remaining = self.request_interval_seconds - elapsed
        if remaining > 0:
            time.sleep(remaining)
        self._last_request_at = time.monotonic()

    def fetch_page(
        self, work_type: str, page: int, page_size: int | None = None
    ) -> dict[str, Any]:
        """拉取单页。返回原始响应体，保留 total / total_pages 供调用方判断终止。"""
        self._throttle()
        resp = self._client.get(
            f"{self.base_url}/api/contents",
            params={
                "type": work_type,
                "page": page,
                "page_size": page_size or self.page_size,
            },
        )
        resp.raise_for_status()
        payload = resp.json()
        return payload if isinstance(payload, dict) else {"items": payload}

    def fetch_raw(self, work_type: str) -> list[dict[str, Any]]:
        """分页拉取某一类型的全部记录。

        终止条件取三者最先满足的：本页为空、已到 total_pages、本页不满。
        max_pages 只是安全阀，正常情况下不会触发。
        """
        collected: list[dict[str, Any]] = []
        for page in range(1, self.max_pages + 1):
            payload = self.fetch_page(work_type, page)
            items = unwrap(payload)
            if not items:
                break
            collected.extend(items)

            total_pages = payload.get("total_pages")
            if isinstance(total_pages, int) and page >= total_pages:
                break
            if len(items) < self.page_size:
                break
        return collected

    def fetch_tags(self, work_type: str, limit: int = 500) -> list[dict[str, Any]]:
        """来源标签词表。返回 [{name, count}]，按 count 降序。

        注意来源返回的是 {type, total, items:[...]} 结构，不是裸数组。
        top 里混有 TV / 剧场版 / 漫画改 这类形式词，使用时要自行过滤。
        """
        self._throttle()
        resp = self._client.get(
            f"{self.base_url}/api/tags", params={"type": work_type, "limit": limit}
        )
        resp.raise_for_status()
        payload = resp.json()
        if isinstance(payload, dict):
            return list(payload.get("items") or [])
        return list(payload or [])

    def search_raw(self, keyword: str, page: int = 1, page_size: int = 20) -> dict[str, Any]:
        """搜索接口，支持真正的分页。当前同步流程未使用，保留给后续增量同步。"""
        self._throttle()
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
            cover_url=clean_cover_url(raw.get("cover_url"), self.base_url),
            release_year=clean_year(raw.get("year")),
            tags=clean_tags(raw.get("tags")),
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
