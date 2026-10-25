"""补跑失败页（--retry-failed）：只抓上次失败的那些页。

来源站实测约四成页会断连，失败是常态。没有补跑就只能整条命令全量重跑
（几小时），有了它补一遍只要几分钟。

这些测试不联网：Source 相关用 monkeypatch 替换 `fetch_page`，
CLI 相关用 monkeypatch 替换 `run`。
"""

import json

import httpx
import pytest

from sync import __main__ as cli
from sync.pipeline import RunReport
from sync.source import OtakuSiteSource


def _source() -> OtakuSiteSource:
    return OtakuSiteSource("http://127.0.0.1:9", request_interval_seconds=0)


def _status_error(status: int) -> httpx.HTTPStatusError:
    request = httpx.Request("GET", "http://127.0.0.1:9/api/contents")
    return httpx.HTTPStatusError(
        f"HTTP {status}", request=request, response=httpx.Response(status, request=request)
    )


def test_transport_error_is_recorded_and_skipped(monkeypatch):
    """断连属于可恢复失败：记账后跳过，不让它中断整批。"""
    with _source() as source:
        monkeypatch.setattr(
            source, "fetch_page", lambda *a, **k: (_ for _ in ()).throw(httpx.TransportError("boom"))
        )
        assert source._fetch_page_recorded("anime", 3) is None

    assert [(f.work_type, f.page) for f in source.failed_pages] == [("anime", 3)]


def test_retryable_status_is_recorded_and_skipped(monkeypatch):
    """5xx 可重试：与断连同样处理。"""
    with _source() as source:
        monkeypatch.setattr(
            source, "fetch_page", lambda *a, **k: (_ for _ in ()).throw(_status_error(503))
        )
        assert source._fetch_page_recorded("anime", 7) is None

    assert source.failed_pages[0].page == 7


def test_fatal_status_is_raised(monkeypatch):
    """400 是请求本身不对，必须抛出，不能当成"坏页"跳过。

    契约第 4.2 节：`type` 传错返回 400。若在这里跳过，等于把致命错误
    静默理解成"该类没有作品"。
    """
    with _source() as source:
        monkeypatch.setattr(
            source, "fetch_page", lambda *a, **k: (_ for _ in ()).throw(_status_error(400))
        )
        with pytest.raises(httpx.HTTPStatusError):
            source._fetch_page_recorded("anime", 1)

    assert source.failed_pages == []


def test_iter_raw_pages_only_requests_given_pages(monkeypatch):
    """补跑只请求指定页，不从第 1 页扫到尾 —— 这正是它省时间的原因。"""
    calls: list[tuple[str, int]] = []

    def fake(work_type, page, page_size=None):
        calls.append((work_type, page))
        return {"items": [{"id": str(page)}], "total_pages": 50}

    with _source() as source:
        monkeypatch.setattr(source, "fetch_page", fake)
        pages = list(source.iter_raw_pages("anime", [2, 17]))

    assert calls == [("anime", 2), ("anime", 17)]
    assert len(pages) == 2


def test_iter_raw_pages_records_failed_page(monkeypatch):
    """补跑里再失败的页仍然记账，下一轮可以继续补。"""
    with _source() as source:
        monkeypatch.setattr(
            source, "fetch_page", lambda *a, **k: (_ for _ in ()).throw(httpx.TransportError("boom"))
        )
        assert list(source.iter_raw_pages("anime", [5])) == []

    assert source.failed_pages[0].page == 5


def test_retry_failed_without_report_is_rejected(tmp_path, capsys):
    """没有运行报告时明确报错，而不是退化成全量重跑（那正是要避免的）。"""
    code = cli.main(
        ["--retry-failed", "--out", str(tmp_path), "--limit", "1", "--dry-run"]
    )
    assert code == 2
    assert "没有找到任何运行报告" in capsys.readouterr().err


def test_retry_failed_with_no_failed_pages_is_noop(tmp_path, capsys):
    report = tmp_path / "run-2026-10-26T00-00-00.json"
    report.write_text(
        json.dumps({"source": "otaku_site", "failed_pages": []}), encoding="utf-8"
    )

    code = cli.main(
        ["--retry-failed", "--out", str(tmp_path), "--limit", "1", "--dry-run"]
    )
    assert code == 0
    assert "没有失败页" in capsys.readouterr().out


def test_retry_failed_passes_pages_to_run(tmp_path, monkeypatch, capsys):
    """报告里的失败页原样交给 run，且只带这些页。"""
    report = tmp_path / "run-2026-10-26T00-00-00.json"
    report.write_text(
        json.dumps(
            {
                "source": "otaku_site",
                "failed_pages": [
                    {"work_type": "anime", "page": 4, "reason": "boom"},
                    {"work_type": "comic", "page": 9, "reason": "boom"},
                ],
            }
        ),
        encoding="utf-8",
    )

    seen: dict[str, object] = {}

    def fake_run(config, **kwargs):
        seen.update(kwargs)
        return RunReport(
            started_at="2026-10-26T00:00:00+00:00",
            source="otaku_site",
            work_types=["anime", "comic"],
            dry_run=True,
        )

    monkeypatch.setattr(cli, "run", fake_run)

    code = cli.main(["--retry-failed", "--out", str(tmp_path), "--dry-run"])
    assert code == 0

    retry = seen.get("retry_failed")
    assert retry is not None
    assert [(f.work_type, f.page) for f in retry] == [("anime", 4), ("comic", 9)]


def test_retry_failed_conflicts_with_articles(capsys):
    """补跑目前只支持作品抓取，与资讯同用时明确拒绝。"""
    code = cli.main(["--retry-failed", "--articles", "--dry-run"])
    assert code == 2
    assert "只支持作品抓取" in capsys.readouterr().err
