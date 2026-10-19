"""来源适配，对应验收 D10（重名各自成作品）。"""

from sync.source import OtakuSiteSource, unwrap


def test_unwrap_accepts_both_shapes():
    assert unwrap({"items": [{"id": 1}]}) == [{"id": 1}]
    assert unwrap([{"id": 1}]) == [{"id": 1}]
    assert unwrap({}) == []


def test_same_title_different_ids_stay_separate(stub):
    """验收 D10：三条同名记录必须成为三条独立条目。"""
    with OtakuSiteSource(stub.base_url) as source:
        items = source.fetch("anime", "2026-10-20T00:00:00+00:00")

    assert [i.source_id for i in items] == ["476", "979", "9999"]
    assert len({i.source_id for i in items}) == 3


def test_cross_type_same_title_is_not_merged(stub):
    """动画与漫画的同名条目各自保留。"""
    with OtakuSiteSource(stub.base_url) as source:
        anime = source.fetch("anime", "2026-10-20T00:00:00+00:00")
        comic = source.fetch("comic", "2026-10-20T00:00:00+00:00")

    assert [i.work_type for i in anime] == ["anime"] * 3
    assert [i.work_type for i in comic] == ["comic"]
    assert comic[0].title == anime[1].title  # 标题相同但属于不同作品


def test_mapping_sets_unprovided_fields_to_none(stub):
    with OtakuSiteSource(stub.base_url) as source:
        item = source.fetch("comic", "2026-10-20T00:00:00+00:00")[0]

    assert item.cover_url is None
    assert item.release_year is None
    assert item.tags is None
    assert item.source_record.source_updated_at is None
    assert item.source_record.source_url.endswith("/api/contents/10900")


def test_blank_summary_maps_to_none(stub):
    with OtakuSiteSource(stub.base_url) as source:
        item = source.fetch("comic", "2026-10-20T00:00:00+00:00")[0]
    assert item.summary is None
