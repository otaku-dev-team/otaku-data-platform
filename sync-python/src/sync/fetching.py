"""抓取骨架：限流、退避重试、失败页记账。

## 为什么单独一个模块

这套规则是**来源无关的**：首站 Otaku（GET 分页）、VNDB（POST 分页）都要求
「串行限流 + 只重试可恢复错误 + 失败的页记账，别悄悄丢数据」。原先它长在
`OtakuSiteSource` 里，第二个站只能靠**继承整个首站适配器**（30 多个方法里
只用 3 个），于是每接一个新站都要连带背上首站的作品/档期/资讯三套映射。

拆出来的边界很清楚：

- `FetchClient` —— 怎么发请求：节流、重试预算、退避、失败记账。不关心抓什么。
- `Source` —— 来源适配器的公共面（`failed_pages` / `close` / 上下文管理）。
- 各来源类 —— 怎么翻页、怎么映射成 `WorkItem`。这部分天生不可复用，
  每个站一份（Otaku 按类型分页、VNDB 用 `more` 标记、下一个站可能用游标）。

## 抓取失败为什么必须记账

来源站是公网服务，实测首站全量里约四成页会中途断连。丢弃一页等于悄悄少了
200 条，而"跑完没报错"会让人误以为数据齐了——所以失败的页进 `failed_pages`，
由调用方写进运行报告并支持补跑（`--retry-failed`）。

只记**可恢复**的失败：网络断连、重试过的 5xx/429/408。400/404/422 是
「请求本身不对」，重试一万次也是同样结果，必须直接抛——尤其 `type` 传错时
站点返回 400，把它当坏页跳过就等于把"类型写错了"误读成"该类没有作品"。
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any, Callable, Protocol, TypeVar

import httpx

T = TypeVar("T")

# 可以安全重试的状态码：408 超时、425 Too Early、429 限流、5xx 服务端临时故障。
# 4xx 里的 400/404/422 是"请求本身不对"，重试一万次也是同样的结果。
RETRYABLE_STATUS = frozenset({408, 425, 429, 500, 502, 503, 504})

# 网络层的瞬时故障。`TransportError` 盖住超时、连接失败与 RemoteProtocolError；
# 最后一种尤其常见——来源站偶发直接断连，不做重试的话一次抖动就能让整批全量抓取白跑。
RETRYABLE_TRANSPORT = httpx.TransportError


@dataclass(frozen=True)
class FailedPage:
    """重试到底仍失败的页。记下来供重跑，别让它悄悄变成"少了几百条"。"""

    work_type: str
    page: int
    reason: str


class Source(Protocol):
    """网络来源适配器的公共面。

    只约束调用方真正依赖的三件事：能进 `with`、能 `close`、失败页可读。
    **刻意不约束 `iter_work_items`**——各站翻页维度不同（首站要传 `work_type`，
    VNDB 没有类型维度、只有单流），强行统一签名会把差异塞进参数默认值里，
    比不统一更麻烦。`pipeline` 因此按来源分支调用，而不是靠一个接口抹平。

    本地档案来源（`BangumiArchiveSource`）不走网络、没有失败页，不在本协议内。
    """

    failed_pages: list[FailedPage]

    def close(self) -> None:
        """释放连接。实现必须幂等：`with` 退出时会被调用一次。"""

    def __enter__(self) -> "Source":
        ...

    def __exit__(self, *exc: object) -> None:
        ...


class FetchClient:
    """带限流与退避重试的 HTTP 客户端。

    只做「怎么把请求安全地发出去」：串行节流、可恢复错误重试、失败记账。
    路径拼接、翻页逻辑、字段映射都归来源适配器。
    """

    def __init__(
        self,
        base_url: str,
        client: httpx.Client | None = None,
        timeout: float = 30.0,
        user_agent: str = "otaku-data-platform-sync/0.1.0",
        request_interval_seconds: float = 0.0,
        max_attempts: int = 4,
        backoff_seconds: float = 2.0,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.request_interval_seconds = max(0.0, request_interval_seconds)
        self.max_attempts = max(1, max_attempts)
        self.backoff_seconds = max(0.0, backoff_seconds)
        self._client = client or httpx.Client(
            timeout=timeout, headers={"User-Agent": user_agent}
        )
        self._owns_client = client is None
        self._last_request_at = 0.0
        # 重试到底也没拿到的页。不静默丢弃：调用方必须把它写进运行报告，
        # 否则"跑完没报错"会让人误以为数据齐了。
        self.failed_pages: list[FailedPage] = []

    def close(self) -> None:
        """只关自己建的连接；外部传入的 client 归调用方管。幂等。"""
        if self._owns_client:
            self._client.close()

    def __enter__(self) -> "FetchClient":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def _throttle(self) -> None:
        """把请求速率压在来源方要求的区间内（首站是 1-2 req/s）。"""
        if self.request_interval_seconds <= 0:
            return
        elapsed = time.monotonic() - self._last_request_at
        remaining = self.request_interval_seconds - elapsed
        if remaining > 0:
            time.sleep(remaining)
        self._last_request_at = time.monotonic()

    def request(
        self,
        method: str,
        path: str,
        params: dict[str, Any] | None = None,
        json: dict[str, Any] | None = None,
    ) -> httpx.Response:
        """带退避重试的请求（GET / POST 通用）。

        来源站是公网服务：个别页要 30 秒以上（DB 慢查询）、偶发直接断连，
        这两种都是**瞬时**的，下一次往往就好了。抓取层原先没有任何重试，
        一次抖动就让整批全量抓取白跑。重试只针对可恢复的错误，
        400/404/422 这类立刻抛出。

        GET 与 POST 收在同一个方法里，是因为限流与退避的规则应当完全一致：
        第二站 VNDB 是 POST + 请求体分页，不该为它再写一套重试。
        """
        last_exc: Exception | None = None
        for attempt in range(1, self.max_attempts + 1):
            self._throttle()
            try:
                resp = self._client.request(
                    method, f"{self.base_url}{path}", params=params, json=json
                )
            except RETRYABLE_TRANSPORT as exc:
                last_exc = exc
            else:
                if resp.status_code not in RETRYABLE_STATUS:
                    resp.raise_for_status()
                    return resp
                last_exc = httpx.HTTPStatusError(
                    f"{resp.status_code} from {path}",
                    request=resp.request,
                    response=resp,
                )
            if attempt < self.max_attempts:
                # 指数退避：2s / 4s / 8s。限流口径按 1-2 req/s 算，
                # 退避期间的等待本身就是额外的让路，不需要再叠加节流。
                time.sleep(self.backoff_seconds * (2 ** (attempt - 1)))
        assert last_exc is not None
        raise last_exc

    def get(self, path: str, params: dict[str, Any] | None = None) -> httpx.Response:
        """带退避重试的 GET。语义见 `request`。"""
        return self.request("GET", path, params=params)

    def post(self, path: str, json: dict[str, Any] | None = None) -> httpx.Response:
        """带退避重试的 POST。语义见 `request`。"""
        return self.request("POST", path, json=json)

    def attempt(self, label: str, page: int, call: Callable[[], T]) -> T | None:
        """执行一次抓取调用，可恢复的失败记账并返回 None，否则抛。

        `label` 进 `FailedPage.work_type`：补跑时按它分组（首站用作品类型
        /`schedule`/`articles`，VNDB 用 `game`）。

        抽这个方法是因为四处翻页循环原本各写一遍同样的 try/except——
        规则一旦漂移，补跑就会漏记或误判。现在只有这一处判定，
        各来源只需说"抓哪一页"。
        """
        try:
            return call()
        except httpx.HTTPStatusError as exc:
            if exc.response.status_code not in RETRYABLE_STATUS:
                raise
            self.failed_pages.append(
                FailedPage(label, page, f"HTTP {exc.response.status_code}")
            )
            return None
        except httpx.TransportError as exc:
            # 跳过这一页继续。丢 200 条可以重跑补，丢整批则前功尽弃。
            self.failed_pages.append(
                FailedPage(label, page, f"{type(exc).__name__}: {exc}")
            )
            return None
