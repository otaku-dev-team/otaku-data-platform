"""来源适配，对应验收 D10（重名各自成作品）。"""

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
    assert item.source_record.source_url.endswith("/api/contents/10900")


def test_cover_url_is_absolutized(stub):
    """来源给的是站内相对路径，必须拼上站点域名。"""
    with OtakuSiteSource(stub.base_url, request_interval_seconds=0) as source:
        item = source.fetch("anime", "2026-10-20T00:00:00+00:00")[0]

    assert item.cover_url == f"{stub.base_url}/media/full/cover_313852.jpg"
    assert item.cover_url.startswith("http")


def test_tags_three_state_semantics(stub):
    """标签三态：有值取列表；空列表是"明确无标签"；字段缺失才是 None。"""
    with OtakuSiteSource(stub.base_url, request_interval_seconds=0) as source:
        anime = source.fetch("anime", "2026-10-20T00:00:00+00:00")
        comic = source.fetch("comic", "2026-10-20T00:00:00+00:00")

    assert anime[0].tags == ["搞笑", "百合", "日常"]
    assert anime[1].tags == []  # 明确无标签，不是 None
    assert comic[0].tags is None  # 来源未提供


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


def test_blank_summary_maps_to_none(stub):
    with OtakuSiteSource(stub.base_url, request_interval_seconds=0) as source:
        item = source.fetch("comic", "2026-10-20T00:00:00+00:00")[0]
    assert item.summary is None
