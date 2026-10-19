"""内部导入客户端的重试与认证行为。"""

import pytest

from sync.importer import ImportDeliveryError, InternalImportError, JavaImporter
from sync.models import SourceRecord, WorkItem


def make_item(source_id: str = "476") -> WorkItem:
    return WorkItem(
        source_record=SourceRecord(source_id=source_id),
        work_type="anime",
        title="街角魔族",
        summary="简介",
    )


def test_retry_then_success(stub):
    """服务端连续两次 503 后恢复：应重试至成功，共三次请求。"""
    stub.reset(fail_times=2)
    importer = JavaImporter(stub.base_url, token="secret", max_attempts=3, backoff_seconds=0.01)
    try:
        result = importer.submit_batch("batch-1", [make_item()], "2026-10-20T00:00:00+00:00")
    finally:
        importer.close()

    assert result.counts["inserted"] == 1
    assert stub.state["attempts"] == 3


def test_exhausted_retries_raise_delivery_error(stub):
    """重试耗尽后必须明确报错，而不是静默成功。"""
    stub.reset(status=503)
    importer = JavaImporter(stub.base_url, token="secret", max_attempts=2, backoff_seconds=0.01)
    try:
        with pytest.raises(ImportDeliveryError):
            importer.submit_batch("batch-2", [make_item()], "2026-10-20T00:00:00+00:00")
    finally:
        importer.close()
    assert stub.state["attempts"] == 2


def test_auth_failure_is_not_retried(stub):
    """认证失败重试无意义，只请求一次。"""
    stub.reset(status=401)
    importer = JavaImporter(stub.base_url, token="bad", max_attempts=3, backoff_seconds=0.01)
    try:
        with pytest.raises(InternalImportError):
            importer.submit_batch("batch-3", [make_item()], "2026-10-20T00:00:00+00:00")
    finally:
        importer.close()
    assert stub.state["attempts"] == 1


def test_missing_token_is_refused_before_any_request(stub):
    importer = JavaImporter(stub.base_url)
    try:
        with pytest.raises(InternalImportError):
            importer.submit_batch("batch-4", [make_item()], "2026-10-20T00:00:00+00:00")
    finally:
        importer.close()
    assert stub.state["attempts"] == 0


def test_token_is_sent_as_header(stub):
    importer = JavaImporter(stub.base_url, token="secret")
    try:
        importer.submit_batch("batch-5", [make_item()], "2026-10-20T00:00:00+00:00")
    finally:
        importer.close()
    assert stub.state["received"][0]["batch_id"] == "batch-5"


def test_payload_uses_null_for_unprovided_fields(stub):
    importer = JavaImporter(stub.base_url, token="secret")
    try:
        importer.submit_batch("batch-6", [make_item()], "2026-10-20T00:00:00+00:00")
    finally:
        importer.close()
    item = stub.state["received"][0]["items"][0]
    assert item["cover_url"] is None
    assert item["release_year"] is None
    assert item["tags"] is None
    assert item["rating"] is None
