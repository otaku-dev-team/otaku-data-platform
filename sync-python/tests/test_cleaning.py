"""清洗与校验规则，对应验收 D5 / D8 / D9。"""

from sync.cleaning import clean_rating, clean_summary, clean_title, validate
from sync.models import Rating, SourceRecord, WorkItem


def make_item(title: str = "标题", work_type: str = "anime", rating: object = 7.0) -> WorkItem:
    return WorkItem(
        source_record=SourceRecord(source_id="1"),
        work_type=work_type,
        title=title,
        summary=None,
        rating=clean_rating(rating),
    )


def test_crlf_is_normalized_to_lf():
    """验收 D8：来源的 \\r\\n 必须统一为 \\n。"""
    assert clean_summary("第一行\r\n第二行\r\n第三行") == "第一行\n第二行\n第三行"


def test_lone_cr_is_also_normalized():
    assert clean_summary("甲\r乙") == "甲\n乙"


def test_long_summary_is_never_truncated():
    """验收 D9：全库最长的 7225 字简介必须完整保留，截断交给客户端折叠。"""
    long_text = "あ" * 7225
    assert len(clean_summary(long_text)) == 7225


def test_blank_summary_becomes_none():
    """空白字符串按"来源未提供"处理，避免空串覆盖已有内容。"""
    assert clean_summary("   ") is None
    assert clean_summary("　") is None
    assert clean_summary(None) is None
    assert clean_summary("") is None


def test_title_is_only_stripped():
    assert clean_title("  街角魔族  ") == "街角魔族"
    assert clean_title(None) == ""


def test_missing_rating_is_none_not_zero():
    """缺失评分不得变成 0 分。"""
    assert clean_rating(None) is None
    assert clean_rating("n/a") is None
    assert clean_rating(0.0) == Rating(value=0.0)


def test_valid_item_passes():
    assert validate(make_item()) == []


def test_empty_title_is_rejected():
    """验收 D5：空标题必须被拒绝，且不牵连同批其他记录。"""
    problems = validate(make_item(title=""))
    assert [code for code, _ in problems] == ["TITLE_REQUIRED"]


def test_unknown_type_is_rejected():
    problems = validate(make_item(work_type="movie"))
    assert [code for code, _ in problems] == ["INVALID_TYPE"]


def test_rating_out_of_scale_is_rejected():
    problems = validate(make_item(rating=99.0))
    assert [code for code, _ in problems] == ["RATING_OUT_OF_SCALE"]
