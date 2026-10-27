"""抓取骨架（`sync/fetching.py`）与「来源不再互相继承」的守卫。

抓取骨架是首站与第三方来源共用的规则，自身必须有直接测试：以前这些规则
只能通过 `OtakuSiteSource` 间接测，一旦有人把判定改成两处实现就会悄悄漂移。
"""

from __future__ import annotations

import time

import httpx
import pytest

from sync.fetching import FailedPage, FetchClient, Source
from sync.source import OtakuSiteSource
from sync.sources.vndb import VndbSource


def _client(handler, **kwargs) -> FetchClient:
    """构造一个走 MockTransport 的 FetchClient（不发真实网络）。"""
    http = httpx.Client(transport=httpx.MockTransport(handler))
    kwargs.setdefault("request_interval_seconds", 0)
    return FetchClient("https://example.test", client=http, **kwargs)


# ----------------------------------------------------------------------
# 失败记账
# ----------------------------------------------------------------------


def test_attempt_records_retryable_status():
    """5xx 重试到底仍失败 → 记账并返回 None（不抛，继续抓下一页）。"""
    client = _client(lambda r: httpx.Response(503), max_attempts=2, backoff_seconds=0)
    assert client.attempt("anime", 3, lambda: client.get("/x")) is None
    assert [(f.work_type, f.page) for f in client.failed_pages] == [("anime", 3)]
    assert "503" in client.failed_pages[0].reason


def test_attempt_raises_on_client_error():
    """400/404/422 是请求本身不对 → 直接抛，**不得**记成坏页跳过。

    站点的 `type` 传错返回 400；若把它当坏页吞掉，就等于把"类型写错了"
    误读成"该类没有作品"——契约第 4.2 节明确禁止这个语义。
    """
    client = _client(lambda r: httpx.Response(422), max_attempts=2, backoff_seconds=0)
    with pytest.raises(httpx.HTTPStatusError):
        client.attempt("anime", 1, lambda: client.get("/x"))
    assert client.failed_pages == []


def test_attempt_records_transport_error():
    """断连（`TransportError`）属于瞬时故障 → 记账跳过。"""

    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.RemoteProtocolError("peer closed", request=request)

    client = _client(handler, max_attempts=1, backoff_seconds=0)
    assert client.attempt("articles", 2, lambda: client.get("/x")) is None
    assert client.failed_pages[0].page == 2
    assert "RemoteProtocolError" in client.failed_pages[0].reason


def test_attempt_returns_value_on_success():
    client = _client(lambda r: httpx.Response(200, text="ok"))
    assert client.attempt("game", 1, lambda: client.get("/x").text) == "ok"
    assert client.failed_pages == []


def test_failed_pages_readable_after_close():
    """`pipeline` 在 `with` 块外读 `failed_pages` 汇总报告，关闭不能清空它。"""
    client = _client(
        lambda r: httpx.Response(500), max_attempts=2, backoff_seconds=0
    )
    client.attempt("anime", 1, lambda: client.get("/x"))
    client.close()
    assert client.failed_pages and client.failed_pages[0].work_type == "anime"


# ----------------------------------------------------------------------
# 重试与限流
# ----------------------------------------------------------------------


def test_retries_until_success():
    """503 一次后成功 → 返回正常响应且不记账（重试预算内不算失败）。"""
    seen: list[int] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(1)
        return httpx.Response(503) if len(seen) == 1 else httpx.Response(200, text="ok")

    client = _client(handler, max_attempts=3, backoff_seconds=0)
    assert client.get("/x").text == "ok"
    assert len(seen) == 2
    assert client.failed_pages == []


def test_does_not_retry_client_error():
    """4xx 一次都不重试：重试一万次也是同样结果，白等退避。"""
    seen: list[int] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(1)
        return httpx.Response(404)

    client = _client(handler, max_attempts=4, backoff_seconds=0)
    with pytest.raises(httpx.HTTPStatusError):
        client.get("/x")
    assert len(seen) == 1


def test_throttle_spaces_requests():
    """限流生效：两次请求之间至少隔 `request_interval_seconds`。"""
    client = _client(lambda r: httpx.Response(200), request_interval_seconds=0.08)
    started = time.monotonic()
    client.get("/a")
    client.get("/b")
    assert time.monotonic() - started >= 0.08


def test_throttle_disabled_by_zero():
    """间隔 0 时不该额外等待（测试与本地联调大量依赖这条）。"""
    client = _client(lambda r: httpx.Response(200), request_interval_seconds=0)
    started = time.monotonic()
    for _ in range(3):
        client.get("/a")
    assert time.monotonic() - started < 0.5


# ----------------------------------------------------------------------
# 连接所有权
# ----------------------------------------------------------------------


def test_does_not_close_injected_client():
    """外部传入的 client 由调用方管，`close()` 不该把它关掉后还让人用。"""
    http = httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(200)))
    client = FetchClient("https://example.test", client=http)
    client.close()
    assert not http.is_closed
    http.close()


def test_owns_client_is_closed():
    client = FetchClient("https://example.test")
    client.close()
    assert client._client.is_closed  # noqa: SLF001 - 断言连接确实被释放


# ----------------------------------------------------------------------
# 结构守卫
# ----------------------------------------------------------------------


def test_vndb_does_not_inherit_otaku_source():
    """第三方来源**组合**抓取骨架，不继承首站适配器。

    继承会让 VNDB 白拿 30 多个首站方法（作品/档期/资讯三套映射），
    改首站时波及不可见的子类——这正是抽出 `FetchClient` 要解决的问题。
    """
    assert not issubclass(VndbSource, OtakuSiteSource)


@pytest.mark.parametrize("cls", [OtakuSiteSource, VndbSource])
def test_sources_expose_common_surface(cls):
    """两类来源都满足 `Source` 协议的公共面（能进 with、能 close、有失败页）。"""
    with cls("https://example.test", request_interval_seconds=0) as source:
        assert source.failed_pages == []
    assert isinstance(FailedPage("x", 1, "r"), FailedPage)
    assert hasattr(Source, "close")
