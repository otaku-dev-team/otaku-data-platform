"""来源适配：VNDB（Visual Novel Database，https://vndb.org）。

## 为什么是 VNDB（W4 第二站实测结论，见 docs/w4-second-site-report.md）

公开只读、无需鉴权（铁律 1）；字段能直接映射进现有 `WorkItem`；视觉小说
落在现有 `work_type` 的 `game` 里，不需要为了验证去动枚举（红线）。W4 探针
30 条一次导入 `rejected=0`。本次把那 40 行一次性脚本落成生产适配器，**复用**
`OtakuSiteSource` 的限流、退避重试与失败记账，而不是另写一套。

## 接口形态

VNDB 公开 API 是 **kana**（POST `https://api.vndb.org/kana/vn`，JSON 请求体）。
与 Otaku 站点的 GET 分页不同，这里用 POST + 请求体里的 `page` / `results`，
响应形如 `{"results":[...], "more": bool}`。翻页终止条件：本页为空或 `more`
为 false（最后一页）——与 `_iter_raw` 的「空页 / 不满页」语义一致。

## 封面白名单（接新站必做）

VNDB 封面在 `t.vndb.org`（如 `https://t.vndb.org/cv/...`），W4 已把
`app.cover.allowed-hosts` 增加 `t.vndb.org:443`。适配器把 `image.url` 原样
透传（绝对地址），交给后端的 fail-closed 白名单决定是否放行。

## 字段映射

| VNDB 字段            | WorkItem 字段        | 说明                                         |
|----------------------|----------------------|----------------------------------------------|
| `id`                 | `source_id`          | 形如 `v17`，原样作为 (source, source_id) 主键 |
| （恒为视觉小说）       | `work_type`          | 固定 `game`（见 `VNDB_WORK_TYPE`）            |
| `title`              | `title`              | 主标题（多为罗马字/英文）                      |
| `description`        | `summary`            | 含 BBCode，先 `_strip_bbcode` 再清洗           |
| `released`           | `release_year`       | 日期取前 4 位年份，`YYYY` / `YYYY-MM` 兼容     |
| `image.url`          | `cover_url`          | 绝对地址原样透传；缺失为 None                  |
| `tags[].name`        | `tags`               | 取前 `VNDB_TAG_LIMIT` 个，去重保序              |
| （无对应）            | `source_url`         | 人读原页 `https://vndb.org/{id}`               |

## 评分（暂不映射 —— 红线，见下方 TODO）

VNDB 的 `rating` 是 **0–100** 尺度，而契约的 `Rating.scale` 固定 `0-10`。
W4 报告已证明：两个来源的尺度不同却一起参与 `sort=rating` / `min_rating`
会让排行榜与过滤**语义错位**。这是改动存储/契约语义的**三人确认红线项**
（Issue #155，方案 A/B/C 待拍板），**不在本次范围内**，故适配器现在
**不映射 `main_rating`**（保持 None），等三人确认后再补归一或强制校验。
"""

from __future__ import annotations

import re
from typing import Any, Iterator

import httpx

from ..cleaning import (
    clean_summary,
    clean_tags,
    clean_year,
    normalize_url,
)
from ..config import (
    DEFAULT_MAX_PAGES,
    DEFAULT_PAGE_SIZE,
    DEFAULT_REQUEST_INTERVAL_SECONDS,
)
from ..models import SourceRecord, WorkItem
from ..source import (
    RETRYABLE_STATUS,
    FailedPage,
    OtakuSiteSource,
)

# kana API 基础地址。封面走单独的 `t.vndb.org`（见模块 docstring）。
DEFAULT_VNDB_API_BASE_URL = "https://api.vndb.org/kana"
# kana 的视觉小说查询端点（POST）。
VN_ENDPOINT = "/vn"

# VNDB 只有视觉小说这一类，契约里对应 `game`。将来若接 VNDB 的其他媒体形态，
# 这里是要扩展的地方——但那需要先动 `work_type` 枚举（红线），不在本次范围。
VNDB_WORK_TYPE = "game"
# 标签只取前 N 个：W4 实测一页 30 条足以覆盖，取前 5 个避免长尾噪声。
VNDB_TAG_LIMIT = 5

# 人读作品原页。VNDB 的 id 形如 `v17`，原页即 `https://vndb.org/v17`。
VNDB_PAGE_URL = "https://vndb.org/{vndb_id}"

# kana 的 `results` 单页上限。**不能沿用 sync 的默认 page_size=200**：
# 那是首站接口的用法（站主要求 200），kana 超限会直接报错、整批拉不下来。
# 上限取 100，是 kana 允许的最大值。
VNDB_MAX_RESULTS_PER_PAGE = 100

# 描述里的 BBCode 形如 `[url=http://x]label[/url]` / `[spoiler]...[/spoiler]`。
# 只摘掉方括号标签、保留标签之间的可见文本，比整段丢弃更贴近原意。
_BBCODE_RE = re.compile(r"\[[^\]]*\]")


def _strip_bbcode(text: str | None) -> str | None:
    """去掉 VNDB 简介里的 BBCode 标签，保留标签之间的可见文本。

    返回 None 表示原本就缺失；空串清洗后返回 None（与 `clean_summary` 口径一致）。
    """
    if text is None:
        return None
    return clean_summary(_BBCODE_RE.sub("", text))


class VndbSource(OtakuSiteSource):
    """从 VNDB kana API 读取视觉小说并映射成 `WorkItem`。

    完整复用父类的限流（`_throttle`）、退避重试（`_request`）与失败记账
    （`failed_pages`）：只覆写「怎么发请求 / 怎么翻页 / 怎么映射」，抓取骨架
    不动。这样接新站 = 一份映射 + 一个白名单条目（W4 结论），不用重写轮子。

    唯一的网络差异是 VNDB 用 POST 而不是 GET——这正是指定 `_request` 而不是
    `_get` 的原因：父类把 GET 与 POST 收在同一个带重试的方法里，子类照用即可。
    """

    def __init__(
        self,
        base_url: str = DEFAULT_VNDB_API_BASE_URL,
        client: httpx.Client | None = None,
        timeout: float = 30.0,
        user_agent: str = "otaku-data-platform-sync/0.1.0",
        page_size: int = DEFAULT_PAGE_SIZE,
        request_interval_seconds: float = DEFAULT_REQUEST_INTERVAL_SECONDS,
        max_pages: int = DEFAULT_MAX_PAGES,
        max_attempts: int = 4,
        backoff_seconds: float = 2.0,
    ) -> None:
        # 父类只认 base_url 当站点根；VNDB 这里就是 kana API 根。
        # page_size 在这里就截到 kana 的上限：超限是「请求本身不对」，
        # 会让整批拉取直接失败（父类的 4xx 不重试、直接抛），所以必须在
        # 发请求前就压好，不能等 API 报错才发现。
        super().__init__(
            base_url=base_url,
            client=client,
            timeout=timeout,
            user_agent=user_agent,
            page_size=min(page_size, VNDB_MAX_RESULTS_PER_PAGE),
            request_interval_seconds=request_interval_seconds,
            max_pages=max_pages,
            max_attempts=max_attempts,
            backoff_seconds=backoff_seconds,
        )

    # ------------------------------------------------------------------
    # 抓取：POST /vn + 分页
    # ------------------------------------------------------------------

    def _post_vn(self, page: int, page_size: int) -> dict[str, Any]:
        """拉一页视觉小说。返回原始响应体 `{"results":[...], "more":bool}`。

        请求体沿用 W4 探针的字段集：`id,title,image.url,description,released,
        tags.name`，按评分降序。VNDB 没有「按类型」的维度（全是视觉小说），
        work_type 统一由 `to_work_item` 落 `game`，故这里不传类型过滤。
        """
        body = {
            "fields": "id,title,image.url,description,released,tags.name",
            "sort": "rating",
            "reverse": True,
            "page": page,
            "results": page_size,
        }
        resp = self._request("POST", VN_ENDPOINT, json=body)
        payload = resp.json()
        return payload if isinstance(payload, dict) else {"results": payload}

    def iter_raw(self) -> Iterator[list[dict[str, Any]]]:
        """逐页产出 VNDB 记录，单页彻底失败时跳过并记账（复用父类口径）。

        终止条件：本页为空、或响应 `more` 为 false、或本页不满一页。`max_pages`
        只是安全阀。错误分类与父类 `iter_raw` 完全一致——可恢复的（5xx/429/
        断连）记进 `failed_pages` 继续，不可恢复的（4xx 请求本身不对）直接抛。
        """
        for page in range(1, self.max_pages + 1):
            try:
                payload = self._post_vn(page, self.page_size)
            except httpx.HTTPStatusError as exc:
                if exc.response.status_code not in RETRYABLE_STATUS:
                    raise
                self.failed_pages.append(
                    FailedPage(VNDB_WORK_TYPE, page, f"HTTP {exc.response.status_code}")
                )
                continue
            except httpx.TransportError as exc:
                self.failed_pages.append(
                    FailedPage(VNDB_WORK_TYPE, page, f"{type(exc).__name__}: {exc}")
                )
                continue

            results = payload.get("results") or []
            if not results:
                break
            yield results

            if not payload.get("more"):
                break
            if len(results) < self.page_size:
                break

    # ------------------------------------------------------------------
    # 映射
    # ------------------------------------------------------------------

    def to_work_item(self, raw: dict[str, Any], fetched_at: str) -> WorkItem:
        """把一条 VNDB 记录映射成导入条目。

        `id` 原样作 source_id（形如 `v17`），与 bangumi/otaku 的 id 体系天然
        隔离，不污染 `(source, source_id)` 唯一键。
        """
        source_id = str(raw.get("id"))
        image = raw.get("image") or {}
        image_url = image.get("url") if isinstance(image, dict) else None

        return WorkItem(
            source_record=SourceRecord(
                source_id=source_id,
                source_url=normalize_url(VNDB_PAGE_URL.format(vndb_id=source_id)),
                fetched_at=fetched_at,
                source_updated_at=None,
            ),
            work_type=VNDB_WORK_TYPE,
            title=raw.get("title") or "",
            summary=_strip_bbcode(raw.get("description")),
            # ------------------------------------------------------------------
            # TODO(W4 #155 / 三人确认): VNDB 评分尺度是 0–100，契约固定 0–10。
            # 现在**不映射** `main_rating`（保持 None），等三人确认以下方案之一：
            #   A 适配器归一：VNDB 的 rating÷10 再提交（本次 W4 探针的做法，
            #      但换算规则是隐式约定，写错没人拦，会静默污染排序）；
            #   B 契约只收 0–10：`scale != "0-10"` 一律 RATING_OUT_OF_SCALE
            #      （倾向方案，一条校验把"静默错"变成"显式错"）；
            #   C 比较时带尺度：索引失效，57 万条上不可行。
            # 在三人确认拍板前，**不得**改动 `Rating` 存储或把 0–100 原值
            # 当成 0–10 提交——那会让 `sort=rating` / `min_rating` 语义错位。
            # 届时在此处补一个 `_normalize_rating(raw)`，并同步更新本模块
            # docstring 的字段映射表。
            # ------------------------------------------------------------------
            main_rating=None,
            cover_url=normalize_url(image_url),
            release_year=clean_year(str(raw.get("released") or "")[:4]),
            tags=self._pick_tags(raw.get("tags")),
        )

    @staticmethod
    def _pick_tags(raw: object) -> list[str] | None:
        """从 VNDB 的 `[{name, score, spoiler}]` 取 name，取前 `VNDB_TAG_LIMIT` 个。

        来源没给 tags 字段 → None（未提供，下游不覆盖）；给了空列表 → `[]`
        （明确无标签）。VNDB 是英文标签，与首站中文标签天然跨源不互通，符合
        「各站独立」定位，不强行对齐。
        """
        if raw is None:
            return None
        if not isinstance(raw, (list, tuple)):
            return None
        names: list[str] = []
        for entry in raw:
            name = entry.get("name") if isinstance(entry, dict) else entry
            text = str(name).strip() if name is not None else ""
            if text and text not in names:
                names.append(text)
            if len(names) >= VNDB_TAG_LIMIT:
                break
        return names or None

    def iter_work_items(self, fetched_at: str) -> Iterator[WorkItem]:
        """逐页产出 WorkItem，失败页跳过（记在 `failed_pages` 里）。"""
        for page_items in self.iter_raw():
            for raw in page_items:
                yield self.to_work_item(raw, fetched_at)

    def fetch(self, fetched_at: str, limit: int | None = None) -> list[WorkItem]:
        """拉取全部（或前 `limit` 条）视觉小说并映射。"""
        items: list[WorkItem] = []
        for item in self.iter_work_items(fetched_at):
            items.append(item)
            if limit is not None and len(items) >= limit:
                break
        return items
