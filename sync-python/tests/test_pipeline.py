"""同步流程编排：分批、校验、幂等键与 dry-run 落盘。"""

import json
import os

from sync.config import SyncConfig
from sync.models import SourceRecord, WorkItem
from sync.pipeline import build_batch_id, chunked, fingerprint, run, summarize


def make_item(source_id: str) -> WorkItem:
    return WorkItem(
        source_record=SourceRecord(source_id=source_id),
        work_type="anime",
        title=f"作品{source_id}",
        summary="简介",
    )


def test_chunked_splits_by_size():
    items = [make_item(str(i)) for i in range(5)]
    assert [len(c) for c in chunked(items, 2)] == [2, 2, 1]


def test_batch_id_is_deterministic_for_same_input():
    """验收 D2：同一批数据重跑得到同一个 batch_id，Java 侧按幂等键不重复入库。"""
    items = [make_item("1"), make_item("2")]
    first = build_batch_id(items, ["anime"], "2026-10-20T00:00:00+00:00")
    second = build_batch_id(list(reversed(items)), ["anime"], "2026-10-20T00:00:00+00:00")
    assert first == second


def test_batch_id_changes_when_data_changes():
    """验收 D3：数据变了才生成新 batch_id，走更新而不是覆盖。"""
    base = [make_item("1")]
    widened = [make_item("1"), make_item("2")]
    assert build_batch_id(base, ["anime"], "2026-10-20T00:00:00+00:00") != build_batch_id(
        widened, ["anime"], "2026-10-20T00:00:00+00:00"
    )


def test_fingerprint_is_stable_regardless_of_order():
    assert fingerprint([make_item("1"), make_item("2")]) == fingerprint(
        [make_item("2"), make_item("1")]
    )


def test_dry_run_writes_payload_and_report(stub, tmp_path):
    config = SyncConfig(
        source_base_url=stub.base_url,
        java_base_url=stub.base_url,
        work_types=("anime",),
        batch_size=2,
        output_dir=str(tmp_path),
    )
    report = run(config, dry_run=True)

    assert report.fetched == 3
    assert report.accepted == 2
    assert report.rejected == 1  # 空标题被拒
    assert report.batches and report.batches[0]["delivered"] is False

    payload_path = report.batches[0]["payload_path"]
    assert os.path.exists(payload_path)
    payload = json.loads(open(payload_path, encoding="utf-8").read())
    assert len(payload["items"]) == 2
    assert all(i["cover_url"] is None for i in payload["items"])
    assert os.path.exists(os.path.join(str(tmp_path), f"run-{report.started_at.replace(':', '').replace('+', 'Z')}.json"))


def test_rejected_items_are_recorded_with_reason(stub, tmp_path):
    config = SyncConfig(
        source_base_url=stub.base_url,
        work_types=("anime",),
        output_dir=str(tmp_path),
    )
    report = run(config, dry_run=True)
    rejected = {(r.source_id, r.reason_code) for r in report.rejected_items}
    assert ("9999", "TITLE_REQUIRED") in rejected


def test_real_submission_against_stub(stub, tmp_path):
    """不经 dry-run 时，批次应真正送达并带回计数。"""
    config = SyncConfig(
        source_base_url=stub.base_url,
        java_base_url=stub.base_url,
        internal_token="secret",
        work_types=("anime",),
        batch_size=10,
        output_dir=str(tmp_path),
    )
    report = run(config, dry_run=False)
    assert report.batches[0]["delivered"] is True
    assert report.batches[0]["counts"]["inserted"] == 2
    assert "入库 inserted=2" in summarize(report)


def test_failed_batch_is_recorded_not_swallowed(stub, tmp_path):
    """验收 D7：接口拒绝时批次必须被记录为未送达。"""
    stub.reset(status=401)
    config = SyncConfig(
        source_base_url=stub.base_url,
        java_base_url=stub.base_url,
        internal_token="bad",
        work_types=("anime",),
        batch_size=10,
        max_attempts=1,
        output_dir=str(tmp_path),
    )
    report = run(config, dry_run=False)
    assert report.batches[0]["delivered"] is False
    assert report.batches[0]["failed_source_ids"] == ["476", "979"]
