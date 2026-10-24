"""档期链路：映射、分页抓取、校验、提交（对应「每日新番」后端侧契约）。

与作品链路平行的口径：坏页跳过记账、确定性 batch_id、逐条校验、
服务端故障与数据问题分开。这里只验证同步侧行为，后端行为由
ScheduleImportServiceTest 兜底。
"""

from __future__ import annotations

import json

from sync.cleaning import (
    parse_platforms,
    parse_weekday,
    split_tags,
    to_iso_utc,
    validate_schedule,
)
from sync.models import ScheduleItem, SourceRecord
from sync.pipeline import run_schedule, schedule_batch_id
from sync.source import OtakuSiteSource


def test_slash_tags_split_into_list():
    assert split_tags("战斗/群像/英雄剧") == ["战斗", "群像", "英雄剧"]
    assert split_tags("  ") is None
    assert split_tags(None) is None
    assert split_tags("///") is None  # 拆不出内容按未提供


def test_weekday_parsing():
    assert parse_weekday(1) == 1
    assert parse_weekday("7") == 7
    assert parse_weekday(None) is None
    # 越界与不可解析都保留/变成会被校验拒收的值，不静默改成"待定"
    assert parse_weekday(0) == 0
    assert parse_weekday(8) == 8
    assert parse_weekday("abc") == 0


def test_platforms_cleaning():
    raw = [
        {"name": "www.bilibili.com", "url": "https://www.bilibili.com/1"},
        {"name": "  ", "url": "javascript:alert(1)"},  # 双空 -> 丢掉
        {"name": None, "url": None},  # 双空 -> 丢掉
    ]
    assert parse_platforms(raw) == [
        {"name": "www.bilibili.com", "url": "https://www.bilibili.com/1"}
    ]
    assert parse_platforms("not a list") is None


def test_site_timestamp_becomes_iso_utc():
    # 站点给 "2026-10-20 06:01:50"（空格分隔、无时区），后端收 OffsetDateTime
    assert to_iso_utc("2026-10-20 06:01:50") == "2026-10-20T06:01:50Z"
    assert to_iso_utc(None) is None


def test_validate_schedule_rejects_bad_weekday_and_missing_title():
    ok = ScheduleItem(
        source_record=SourceRecord(source_id="1"),
        title_main="有标题",
        weekday=3,
    )
    assert validate_schedule(ok) == []

    bad_weekday = ScheduleItem(
        source_record=SourceRecord(source_id="2"),
        title_main="有标题",
        weekday=0,
    )
    problems = validate_schedule(bad_weekday)
    assert [code for code, _ in problems] == ["INVALID_WEEKDAY"]

    no_title = ScheduleItem(
        source_record=SourceRecord(source_id="3"),
        title_main=None,
        title_cn=None,
        title_jp=None,
    )
    problems = validate_schedule(no_title)
    assert [code for code, _ in problems] == ["TITLE_REQUIRED"]


def test_to_schedule_item_maps_site_fields(stub):
    """站点字段 → ScheduleItem：斜杠标签拆数组、时间转 ISO、怪协议 URL 丢弃。"""
    with OtakuSiteSource(stub.base_url, request_interval_seconds=0) as source:
        items = {
            item.source_id: item
            for item in source.iter_schedule_items("2026-10-22T00:00:00+00:00")
        }

    compass = items["469"]
    assert compass.title_main == "#COMPASS 2.0 战斗天赋解析系统"
    assert compass.work_tags == ["战斗", "群像", "英雄剧"]
    assert compass.weekday == 1
    assert compass.content_id == "7267"
    assert compass.source_updated_at == "2026-10-20T06:01:50Z"
    assert compass.platforms == [
        {"name": "www.bilibili.com", "url": "https://www.bilibili.com/1"}
    ]
    assert compass.source_url == "https://yuc.wiki/202504/"

    # content_id 为 null 的条目照样映射（后端留空 work_id）
    arp = items["1470"]
    assert arp.content_id is None
    assert arp.work_tags is None  # 空串按未提供，不传空数组
    assert arp.image_url is None


def test_iter_schedule_paginates_and_skips_bad_page(stub):
    """分页拉取 + 坏页跳过记账：坏页不能让整批白跑。"""
    # 3 条样本、档期 page_size 2 → 2 页；第 1 页注入 503（可恢复，跳过）
    # 页码要用 schedule_page_size：档期的分页与作品的 page_size 是两套，
    # 传错了桩会按 100 切片，第 1 页就把 3 条全返回，第 2 页反而是空的。
    entries = list(stub.state["schedule"])[:3]
    stub.reset(schedule=entries, failing_pages={1})
    with OtakuSiteSource(
        stub.base_url, request_interval_seconds=0, schedule_page_size=2
    ) as source:
        pages = list(source.iter_schedule_raw())

    assert pages, "第 2 页应当拿到（坏的是第 1 页）"
    assert len(pages[0]) == 1  # 第 2 页只有 1 条
    assert source.failed_pages, "坏页必须记账"
    assert source.failed_pages[0].work_type == "schedule"


def test_dry_run_writes_payload_without_submitting(stub, tmp_path):
    stub.reset()
    report = run_schedule(
        _config(stub),
        dry_run=True,
        output_dir=str(tmp_path),
    )

    assert report.fetched == 4
    assert report.accepted == 2  # 469、1470 通过校验
    assert report.rejected == 2  # weekday=0、无标题
    assert stub.state["received"] == []  # dry-run 不联系 Java

    payloads = list(tmp_path.glob("batch-*.json"))
    assert payloads, "dry-run 必须落盘载荷"
    payload = json.loads(payloads[0].read_text(encoding="utf-8"))
    assert payload["items"][0]["source_id"] == "469"
    assert payload["items"][0]["work_tags"] == ["战斗", "群像", "英雄剧"]
    assert payload["items"][0]["source_updated_at"] == "2026-10-20T06:01:50Z"


def test_submit_posts_to_schedule_endpoint(stub, tmp_path):
    stub.reset()
    report = run_schedule(
        _config(stub),
        dry_run=False,
        output_dir=str(tmp_path),
    )

    assert report.batches, "应有批次"
    assert all(b.get("delivered") for b in report.batches)
    received = stub.state["received"]
    assert received, "应收到提交"
    assert all(item["source_id"] in ("469", "1470") for item in received[0]["items"])


def test_schedule_batch_id_is_deterministic():
    items = [
        ScheduleItem(source_record=SourceRecord(source_id=str(i)))
        for i in (3, 1, 2)
    ]
    first = schedule_batch_id(items, "2026-10-22T00:00:00+00:00")
    second = schedule_batch_id(
        list(reversed(items)), "2026-10-22T12:00:00+00:00"
    )
    assert first == second  # 同集合同一天 -> 同 id（与日期时刻无关）
    assert "-schedule-" in first  # 与作品批次的 id 空间分开


def _config(stub):
    from sync.config import SyncConfig

    return SyncConfig(
        source_base_url=stub.base_url,
        java_base_url=stub.base_url,
        internal_token="test-token",
        source="otaku_site",
        batch_size=100,
        request_interval_seconds=0,
    )
