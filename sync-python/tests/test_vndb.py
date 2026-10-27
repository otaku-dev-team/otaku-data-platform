"""VNDB 适配器（W4 第二站）。

全离线：`httpx.MockTransport` 接管请求，不建立真实连接，
因此不受 conftest 的网络守卫影响（也不需要 OTAKU_TEST_ALLOW_NETWORK）。

覆盖：字段映射、类型映射、封面透传、BBCode 清洗、标签三态、
分页终止、失败页记账、评分红线（不映射 rating）、CLI 注册。
"""

from __future__ import annotations

import httpx
import pytest

from sync.config import SOURCE_VNDB, SyncConfig
from sync.sources.vndb import (
    DEFAULT_VNDB_API_BASE_URL,
    VNDB_MAX_RESULTS_PER_PAGE,
    VndbSource,
)


def _vn(  # noqa: D103 - 测试夹具
    vndb_id: str = "v17",
    title: str = "Ever17",
    description: str | None = "A story set on an island.",
    released: str | None = "2002-08-29",
    image: dict | None = None,
    tags: list | None = None,
) -> dict:
    """构造一条 kana /vn 记录（字段名对齐 VNDB kana 响应）。"""
    record: dict = {"id": vndb_id, "title": title}
    if description is not None:
        record["description"] = description
    if released is not None:
        record["released"] = released
    if image is not None:
        record["image"] = image
    if tags is not None:
        record["tags"] = tags
    return record


def _source(handler, **kwargs) -> VndbSource:
    """构造一个走 MockTransport 的 VndbSource。"""
    client = httpx.Client(transport=httpx.MockTransport(handler))
    return VndbSource(
        base_url=DEFAULT_VNDB_API_BASE_URL,
        client=client,
        request_interval_seconds=0,
        **kwargs,
    )


# ----------------------------------------------------------------------
# 字段映射
# ----------------------------------------------------------------------


def test_maps_core_fields():
    """VNDB 字段映射进 WorkItem：id / title / 简介 / 年份 / 封面。"""
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"results": [_vn()], "more": False})

    with _source(handler) as source:
        item = next(source.iter_work_items("2026-10-27T00:00:00+00:00"))

    assert item.source_id == "v17"
    assert item.title == "Ever17"
    assert item.summary == "A story set on an island."
    assert item.release_year == 2002
    assert item.source_record.source_url == "https://vndb.org/v17"


def test_work_type_is_game():
    """VNDB 只有视觉小说一种，落在契约既有的 game 里（不扩枚举）。"""
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"results": [_vn()], "more": False})

    with _source(handler) as source:
        item = next(source.iter_work_items("2026-10-27T00:00:00+00:00"))

    assert item.work_type == "game"


def test_cover_url_is_passed_through_unchanged():
    """封面是 t.vndb.org 的绝对地址，原样透传给后端的 fail-closed 白名单。"""
    cover = "https://t.vndb.org/cv/1234.jpg"

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200, json={"results": [_vn(image={"url": cover})], "more": False}
        )

    with _source(handler) as source:
        item = next(source.iter_work_items("2026-10-27T00:00:00+00:00"))

    assert item.cover_url == cover


def test_missing_cover_is_none():
    """来源没给封面 → None（未提供），不是空串。"""
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"results": [_vn()], "more": False})

    with _source(handler) as source:
        item = next(source.iter_work_items("2026-10-27T00:00:00+00:00"))

    assert item.cover_url is None


def test_bbcode_is_stripped_from_summary():
    """简介里的 BBCode 标签要去掉，保留可见文本。"""
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "results": [
                    _vn(description="[url=http://x]link[/url] and [spoiler]hidden[/spoiler] text")
                ],
                "more": False,
            },
        )

    with _source(handler) as source:
        item = next(source.iter_work_items("2026-10-27T00:00:00+00:00"))

    assert "[" not in (item.summary or "")
    assert "link" in (item.summary or "")
    assert "text" in (item.summary or "")


def test_missing_description_is_none():
    """来源没给简介 → None。"""
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200, json={"results": [_vn(description=None)], "more": False}
        )

    with _source(handler) as source:
        item = next(source.iter_work_items("2026-10-27T00:00:00+00:00"))

    assert item.summary is None


def test_year_takes_first_four_digits():
    """released 是完整日期，取前 4 位年份。"""
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200, json={"results": [_vn(released="2026-03")], "more": False}
        )

    with _source(handler) as source:
        item = next(source.iter_work_items("2026-10-27T00:00:00+00:00"))

    assert item.release_year == 2026


def test_missing_released_is_none():
    """来源没给发行日期 → None。"""
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200, json={"results": [_vn(released=None)], "more": False}
        )

    with _source(handler) as source:
        item = next(source.iter_work_items("2026-10-27T00:00:00+00:00"))

    assert item.release_year is None


# ----------------------------------------------------------------------
# 标签
# ----------------------------------------------------------------------


def test_tags_are_capped_and_deduped():
    """标签取前 5 个并去重保序。"""
    raw_tags = [{"name": f"tag{i}"} for i in range(8)]

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200, json={"results": [_vn(tags=raw_tags)], "more": False}
        )

    with _source(handler) as source:
        item = next(source.iter_work_items("2026-10-27T00:00:00+00:00"))

    assert item.tags == ["tag0", "tag1", "tag2", "tag3", "tag4"]


def test_tags_missing_is_none():
    """来源没给 tags → None（未提供，不覆盖）。"""
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200, json={"results": [_vn(tags=None)], "more": False}
        )

    with _source(handler) as source:
        item = next(source.iter_work_items("2026-10-27T00:00:00+00:00"))

    assert item.tags is None


# ----------------------------------------------------------------------
# 评分红线（Issue #155，待三人确认）
# ----------------------------------------------------------------------


def test_rating_is_not_mapped():
    """VNDB 评分是 0–100，契约固定 0–10。

    在三人确认拍板前**不映射评分**（保持 None）——否则 90.6 会和首站的
    9.0 一起参与 sort=rating 比较，排行榜语义错位。见 docs/w4-second-site-report.md §5。
    """
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200, json={"results": [_vn()], "more": False}
        )

    with _source(handler) as source:
        item = next(source.iter_work_items("2026-10-27T00:00:00+00:00"))

    assert item.main_rating is None


# ----------------------------------------------------------------------
# 分页与失败记账
# ----------------------------------------------------------------------


def test_pagination_stops_when_more_is_false():
    """响应里 more=false 即终止，不再多要一页。"""
    calls: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        body = _json_body(request)
        calls.append(body)
        if body["page"] == 1:
            return httpx.Response(
                200,
                json={
                    "results": [_vn(vndb_id="v1"), _vn(vndb_id="v2")],
                    "more": True,
                },
            )
        return httpx.Response(
            200, json={"results": [_vn(vndb_id="v3")], "more": False}
        )

    with _source(handler, page_size=2) as source:
        items = list(source.iter_work_items("2026-10-27T00:00:00+00:00"))

    assert [i.source_id for i in items] == ["v1", "v2", "v3"]
    assert len(calls) == 2


def test_failed_page_is_recorded_and_skipped():
    """单页彻底失败 → 记进 failed_pages 并继续，不让整批报废。"""
    def handler(request: httpx.Request) -> httpx.Response:
        body = _json_body(request)
        if body["page"] == 1:
            return httpx.Response(200, json={"results": [_vn(vndb_id="v1")], "more": True})
        if body["page"] == 2:
            return httpx.Response(500)
        return httpx.Response(200, json={"results": [_vn(vndb_id="v3")], "more": False})

    with _source(handler, page_size=1, max_attempts=1) as source:
        items = list(source.iter_work_items("2026-10-27T00:00:00+00:00"))

    assert [i.source_id for i in items] == ["v1", "v3"]
    assert len(source.failed_pages) == 1
    assert source.failed_pages[0].page == 2


def test_client_error_raises():
    """请求本身不对（4xx）直接抛，不当成坏页跳过。"""
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(422)

    with _source(handler, max_attempts=1) as source:
        with pytest.raises(httpx.HTTPStatusError):
            list(source.iter_work_items("2026-10-27T00:00:00+00:00"))


def test_page_size_is_capped_to_kana_limit():
    """kana 单页上限 100：传更大的 page_size 要在发请求前就压下来。"""
    seen: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(_json_body(request))
        return httpx.Response(200, json={"results": [], "more": False})

    with _source(handler, page_size=200) as source:
        list(source.iter_work_items("2026-10-27T00:00:00+00:00"))

    assert seen[0]["results"] == VNDB_MAX_RESULTS_PER_PAGE


def test_posts_to_vn_endpoint():
    """kana 的视觉小说端点是 POST /vn，请求体带 fields/sort/page/results。"""
    seen: list[tuple[str, dict]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append((request.method, _json_body(request)))
        return httpx.Response(200, json={"results": [], "more": False})

    with _source(handler) as source:
        list(source.iter_work_items("2026-10-27T00:00:00+00:00"))

    method, body = seen[0]
    assert method == "POST"
    assert body["page"] == 1
    assert "title" in body["fields"]


# ----------------------------------------------------------------------
# 注册（config / pipeline / CLI）
# ----------------------------------------------------------------------


def test_vndb_is_a_valid_source():
    """vndb 已进 VALID_SOURCES，可被 --source 选中。"""
    from sync.config import VALID_SOURCES

    assert SOURCE_VNDB in VALID_SOURCES


def test_config_has_separate_vndb_base_url():
    """VNDB 的 base_url 与首站的 source_base_url 分开，不会打到首站。"""
    config = SyncConfig(source=SOURCE_VNDB)

    assert config.vndb_base_url == DEFAULT_VNDB_API_BASE_URL
    # 首站默认值不该被 VNDB 继承
    assert config.vndb_base_url != config.source_base_url


def test_config_reads_vndb_base_url_from_env(monkeypatch):
    monkeypatch.setenv("OTAKU_VNDB_BASE_URL", "http://127.0.0.1:9/kana")
    config = SyncConfig.from_env()

    assert config.vndb_base_url == "http://127.0.0.1:9/kana"


def test_cli_accepts_vndb_source():
    """CLI 能选 vndb（--help 的 choices 里含它）。"""
    from sync.__main__ import build_parser

    parser = build_parser()
    args = parser.parse_args(["--source", "vndb", "--dry-run"])

    assert args.source == "vndb"


def test_cli_rejects_type_for_vndb(capsys):
    """VNDB 无类型维度：--source vndb 配 --type 要明确报错，不能静默忽略。"""
    from sync.__main__ import main

    code = main(["--source", "vndb", "--type", "anime", "--dry-run"])

    assert code == 2
    assert "vndb" in capsys.readouterr().err


def _json_body(request: httpx.Request) -> dict:
    import json

    return json.loads(request.content.decode("utf-8"))
