"""来源适配，对应验收 D10（重名各自成作品）。"""

import httpx
import pytest

from sync.source import OtakuSiteSource, unwrap


def test_unwrap_accepts_both_shapes():
    assert unwrap({"items": [{"id": 1}]}) == [{"id": 1}]
    assert unwrap([{"id": 1}]) == [{"id": 1}]
    assert unwrap({}) == []


def test_same_title_different_ids_stay_separate(stub):
    """验收 D10：三条同名记录必须成为三条独立条目。"""
    with OtakuSiteSource(stub.base_url, request_interval_seconds=0) as source:
        items = source.fetch("anime", "2026-10-20T00:00:00+00:00")

    assert [i.source_id for i in items] == ["476", "979", "9999"]
    assert len({i.source_id for i in items}) == 3


def test_cross_type_same_title_is_not_merged(stub):
    """动画与漫画的同名条目各自保留。"""
    with OtakuSiteSource(stub.base_url, request_interval_seconds=0) as source:
        anime = source.fetch("anime", "2026-10-20T00:00:00+00:00")
        comic = source.fetch("comic", "2026-10-20T00:00:00+00:00")

    assert [i.work_type for i in anime] == ["anime"] * 3
    assert [i.work_type for i in comic] == ["comic"]
    assert comic[0].title == anime[1].title  # 标题相同但属于不同作品


def test_missing_optional_fields_map_to_none(stub):
    """来源未返回 cover_url / tags / year 时，映射为 None（来源未提供）。"""
    with OtakuSiteSource(stub.base_url, request_interval_seconds=0) as source:
        item = source.fetch("comic", "2026-10-20T00:00:00+00:00")[0]

    assert item.cover_url is None
    assert item.release_year is None
    assert item.tags is None
    assert item.source_record.source_updated_at is None
    assert item.source_record.source_url.endswith("/contents/10900")


def test_cover_url_is_absolutized(stub):
    """来源给的是站内相对路径，必须拼上站点域名。"""
    with OtakuSiteSource(stub.base_url, request_interval_seconds=0) as source:
        item = source.fetch("anime", "2026-10-20T00:00:00+00:00")[0]

    assert item.cover_url == f"{stub.base_url}/media/full/cover_313852.jpg"
    assert item.cover_url.startswith("http")


def test_tags_empty_is_treated_as_absent(stub):
    """站点的 [] 一律按"未提供"处理，不当作"明确无标签"。

    站点只有一个空值形态，无法区分"确实没有标签"与"还没录入"（实测 38.5% 为 []）。
    契约里 null 不覆盖、[] 可清空，若把 [] 当"明确无标签"，一次缺数据就会
    清空平台已有标签。故适配器统一转 null。见契约第 4.4.3 节。
    """
    with OtakuSiteSource(stub.base_url, request_interval_seconds=0) as source:
        anime = source.fetch("anime", "2026-10-20T00:00:00+00:00")
        comic = source.fetch("comic", "2026-10-20T00:00:00+00:00")

    assert anime[0].tags == ["搞笑", "百合", "日常"]
    assert anime[1].tags is None  # 站点返回 []，转成"未提供"
    assert comic[0].tags is None  # 字段缺失，同样是"未提供"


def test_year_maps_when_present(stub):
    """年份大部分为空（来源已知缺口），但有值时要正确映射。"""
    with OtakuSiteSource(stub.base_url, request_interval_seconds=0) as source:
        anime = source.fetch("anime", "2026-10-20T00:00:00+00:00")

    assert anime[0].release_year is None  # year 为 null
    assert anime[1].release_year == 2021


def test_fetch_raw_uses_pagination(stub):
    """必须走分页，不能一次拉全量（来源明确要求 page_size<=200）。"""
    with OtakuSiteSource(
        stub.base_url, request_interval_seconds=0, page_size=2
    ) as source:
        raw = source.fetch_raw("anime")

    assert len(raw) == 3  # 三条 anime
    assert stub.state["pages_requested"] == [1, 2]  # 翻到不满一页即停止


def test_pagination_stops_at_total_pages(stub):
    """翻页不应越界，最后一页满页时靠 total_pages 终止。"""
    with OtakuSiteSource(
        stub.base_url, request_interval_seconds=0, page_size=1
    ) as source:
        raw = source.fetch_raw("comic")

    assert len(raw) == 1
    assert stub.state["pages_requested"] == [1]


def test_fetch_tags_unwraps_items(stub):
    """/api/tags 返回的是 {type,total,items:[...]}，不是裸数组。"""
    with OtakuSiteSource(stub.base_url, request_interval_seconds=0) as source:
        tags = source.fetch_tags("anime", limit=3)

    assert len(tags) == 3
    assert tags[0] == {"name": "TV", "count": 2974}


def test_source_url_is_human_readable_page(stub):
    """`source_url` 必须是人读原页 `/contents/{id}`，不是 `/api/contents/{id}`。

    2026-10-21 实测：站点首页渲染的卡片链接就是 `/contents/{id}`，
    `GET /contents/476` 返回 200 且标题为作品名。客户端拿它做「在来源站查看」回流入口，
    指到 API 地址（返回 JSON）等于给个无效入口。
    """
    with OtakuSiteSource(stub.base_url, request_interval_seconds=0) as source:
        item = source.fetch("anime", "2026-10-20T00:00:00+00:00")[0]

    assert item.source_record.source_url == f"{stub.base_url}/contents/476"
    assert "/api/" not in item.source_record.source_url
    assert item.to_payload()["source_url"] == f"{stub.base_url}/contents/476"


def test_payload_carries_null_source_url_when_unknown(stub):
    """无法可靠确定原页时提交 null，不猜测生成地址（契约第 2.1 节）。"""
    with OtakuSiteSource(stub.base_url, request_interval_seconds=0) as source:
        item = source.fetch("anime", "2026-10-20T00:00:00+00:00")[0]

    item.source_record.source_url = None
    assert item.to_payload()["source_url"] is None


def test_blank_summary_maps_to_none(stub):
    with OtakuSiteSource(stub.base_url, request_interval_seconds=0) as source:
        item = source.fetch("comic", "2026-10-20T00:00:00+00:00")[0]
    assert item.summary is None


def test_transient_5xx_is_retried(stub):
    """来源站偶发 503：重试一次就该过，不应该整批报废。"""
    stub.reset(get_fail_times=1)
    with OtakuSiteSource(
        stub.base_url,
        request_interval_seconds=0,
        page_size=2,
        backoff_seconds=0,
    ) as source:
        raw = source.fetch_raw("anime")

    assert len(raw) == 3
    assert source.failed_pages == []


def test_page_that_never_recovers_is_skipped_and_recorded(stub):
    """重试到底仍失败的页：跳过继续，并记进 failed_pages 供重跑。

    不能"整批报废"——实测来源站 55 页里 23 页断连，那样跑一次颗粒无收；
    也不能静默丢弃——那样"跑完没报错"会让人误以为数据齐了。
    """
    stub.reset(failing_pages={2})
    with OtakuSiteSource(
        stub.base_url,
        request_interval_seconds=0,
        page_size=2,
        max_attempts=2,
        backoff_seconds=0,
    ) as source:
        pages = list(source.iter_raw("anime"))

    # 第 1 页拿到，第 2 页跳过；第 2 页不满页不会被当作"结束"
    assert [len(p) for p in pages] == [2]
    assert [(f.work_type, f.page) for f in source.failed_pages] == [("anime", 2)]
    assert "503" in source.failed_pages[0].reason


def test_iter_work_items_keeps_going_after_a_bad_page(stub):
    """流式产出：坏页之后的页照常入库，不是全丢。"""
    stub.reset(failing_pages={2})
    with OtakuSiteSource(
        stub.base_url,
        request_interval_seconds=0,
        page_size=1,
        max_attempts=2,
        backoff_seconds=0,
    ) as source:
        ids = [i.source_id for i in source.iter_work_items("anime", "2026-10-20T00:00:00+00:00")]

    # 三条 anime 里，第 2 页那条（979）丢了，第 3 页的（9999）还在
    assert ids == ["476", "9999"]


def test_non_retryable_4xx_is_fatal_not_skipped(stub):
    """400 必须抛出去，不能当"坏页"跳过。

    契约第 4.2 节：`type` 传错返回 400（不是空列表），必须当致命错误，
    不能理解成"该类没有作品"。若把它算成坏页、记进 failed_pages 继续跑，
    就等于又退回到那个被明确否定的语义——跑完一堆 0 条还显示"成功"。
    """
    stub.reset(failing_pages={2}, failing_pages_status=400)
    with OtakuSiteSource(
        stub.base_url,
        request_interval_seconds=0,
        page_size=2,
        max_attempts=2,
        backoff_seconds=0,
    ) as source:
        with pytest.raises(httpx.HTTPStatusError) as excinfo:
            list(source.iter_raw("anime"))

    assert excinfo.value.response.status_code == 400
    assert source.failed_pages == []  # 没被当成可跳过的坏页
