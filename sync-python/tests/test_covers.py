"""封面回填的离线测试。

全部走内存假对象（httpx.MockTransport + 假 importer），不发任何真实网络请求：
上游是别人的公共服务，测试不该去打扰它。
"""

from __future__ import annotations

import json
import zipfile
from pathlib import Path

import httpx
import pytest

from sync.config import (
    DEFAULT_COVER_INTERVAL_SECONDS,
    DEFAULT_COVER_WORKERS,
    SOURCE_BANGUMI,
    SyncConfig,
)
from sync.covers import (
    REASON_NETWORK,
    REASON_NOT_FOUND,
    REASON_NO_IMAGES,
    REASON_OK,
    STATE_ERROR,
    STATE_FILLED,
    STATE_MISSING,
    STATE_PENDING,
    BangumiSubjectClient,
    CoverIndex,
    build_index,
    extract_cover_url,
    popularity_of,
    run_backfill,
    summarize,
)
from sync.models import BatchResult

ARCHIVE_SUBJECTS = [
    # (id, type, platform, name, name_cn, favorite)
    (10, 2, 0, "Cowboy Bebop", "星际牛仔", {"wish": 10, "done": 200, "doing": 1}),
    (11, 2, 0, "Texhnolyze", "", {"wish": 3, "done": 20}),
    (12, 4, 0, "Ever17", "时空轮回", {"wish": 5, "done": 300}),
    (13, 1, 1001, "One Piece (1)", "", {"wish": 1, "done": 100}),
    # 音乐（type=3）不在契约四类里，应被排除
    (14, 3, 0, "Some OST", "", {"wish": 1}),
    # 画集（platform=1006）也不在四类里
    (15, 1, 1006, "Art Book", "", {"wish": 1}),
]


def _write_archive(path: Path, rows: list[dict]) -> str:
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        lines = "\n".join(json.dumps(row, ensure_ascii=False) for row in rows)
        archive.writestr("subject.jsonlines", lines + "\n")
    return str(path)


def _row(subject_id: int, subject_type: int, platform: int, name: str,
         name_cn: str, favorite: dict) -> dict:
    return {
        "id": subject_id,
        "type": subject_type,
        "platform": platform,
        "name": name,
        "name_cn": name_cn,
        "favorite": favorite,
    }


@pytest.fixture()
def archive_path(tmp_path: Path) -> str:
    rows = [_row(*entry) for entry in ARCHIVE_SUBJECTS]
    return _write_archive(tmp_path / "dump.zip", rows)


class FakeCoverClient:
    """按 id 返回预置结果，并记录被问了哪些 id。"""

    def __init__(self, answers: dict[str, tuple[str | None, str]]):
        self.answers = answers
        self.asked: list[str] = []
        self.closed = False

    def fetch_cover(self, subject_id: str) -> tuple[str | None, str]:
        self.asked.append(subject_id)
        return self.answers.get(subject_id, (None, REASON_NO_IMAGES))

    def close(self) -> None:
        self.closed = True


class FakeImporter:
    def __init__(self) -> None:
        self.batches: list[dict] = []
        self.closed = False

    def submit_batch(self, batch_id, items, fetched_at, source=SOURCE_BANGUMI):
        payloads = [item.to_payload() for item in items]
        self.batches.append(
            {"batch_id": batch_id, "source": source, "items": payloads}
        )
        return BatchResult(
            batch_id=batch_id,
            counts={"inserted": 0, "updated": len(payloads), "unchanged": 0, "rejected": 0},
        )

    def close(self) -> None:
        self.closed = True


class TestExtractCoverUrl:
    def test_prefers_large_over_common(self):
        subject = {
            "images": {
                "large": "https://img/l.jpg",
                "common": "https://img/c.jpg",
                "medium": "https://img/m.jpg",
            }
        }
        assert extract_cover_url(subject) == ("https://img/l.jpg", REASON_OK)

    def test_falls_back_when_large_missing(self):
        subject = {"images": {"large": None, "common": "https://img/c.jpg"}}
        assert extract_cover_url(subject) == ("https://img/c.jpg", REASON_OK)

    def test_blank_string_is_not_a_cover(self):
        subject = {"images": {"large": "   ", "medium": "https://img/m.jpg"}}
        assert extract_cover_url(subject) == ("https://img/m.jpg", REASON_OK)

    def test_missing_images_block(self):
        assert extract_cover_url({}) == (None, REASON_NO_IMAGES)

    def test_all_sizes_empty(self):
        assert extract_cover_url({"images": {"large": None, "common": ""}}) == (
            None,
            REASON_NO_IMAGES,
        )


class TestSubjectClient:
    def _client(self, handler, **kwargs) -> BangumiSubjectClient:
        transport = httpx.MockTransport(handler)
        return BangumiSubjectClient(
            "https://bgm.example",
            client=httpx.Client(transport=transport),
            backoff_seconds=0,
            **kwargs,
        )

    def test_reads_cover_from_response(self):
        def handler(request: httpx.Request) -> httpx.Response:
            assert request.url.path == "/v0/subjects/42"
            return httpx.Response(200, json={"id": 42, "images": {"large": "https://i/42.jpg"}})

        assert self._client(handler).fetch_cover("42") == ("https://i/42.jpg", REASON_OK)

    def test_404_is_missing_not_error(self):
        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(404, json={"message": "Not Found"})

        assert self._client(handler).fetch_cover("7") == (None, REASON_NOT_FOUND)

    def test_retries_on_503_then_succeeds(self):
        calls = {"n": 0}

        def handler(request: httpx.Request) -> httpx.Response:
            calls["n"] += 1
            if calls["n"] == 1:
                return httpx.Response(503)
            return httpx.Response(200, json={"images": {"large": "https://i/x.jpg"}})

        client = self._client(handler, max_attempts=2)
        assert client.fetch_cover("1") == ("https://i/x.jpg", REASON_OK)
        assert calls["n"] == 2

    def test_gives_up_after_attempts(self):
        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(503)

        client = self._client(handler, max_attempts=2)
        assert client.fetch_cover("1") == (None, REASON_NETWORK)

    def test_404_is_not_retried(self):
        calls = {"n": 0}

        def handler(request: httpx.Request) -> httpx.Response:
            calls["n"] += 1
            return httpx.Response(404)

        self._client(handler, max_attempts=3).fetch_cover("1")
        assert calls["n"] == 1

    def test_token_goes_to_authorization_header(self):
        seen = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["auth"] = request.headers.get("authorization")
            return httpx.Response(200, json={"images": {"large": "https://i/1.jpg"}})

        client = BangumiSubjectClient(
            "https://bgm.example",
            token="secret-token",
            client=httpx.Client(transport=httpx.MockTransport(handler)),
            backoff_seconds=0,
        )
        client.fetch_cover("1")
        assert seen["auth"] == "Bearer secret-token"


class TestIndex:
    def test_popularity_sums_favorite_states(self):
        assert popularity_of({"favorite": {"wish": 1, "done": 2, "doing": 3}}) == 6
        assert popularity_of({"favorite": None}) == 0
        assert popularity_of({}) == 0

    def test_build_index_filters_types_and_keeps_popularity(self, archive_path):
        with CoverIndex(":memory:") as index:
            stats = build_index(index, archive_path)
            assert stats["scanned"] == len(ARCHIVE_SUBJECTS)
            assert stats["indexed"] == 4  # 动画 2 + 游戏 1 + 漫画 1
            assert stats["excluded"] == 2  # 音乐、画集
            counts = index.counts()
            assert counts[STATE_PENDING] == 4
            # 热度最高的 Ever17（305）排第一
            assert [row[0] for row in index.pending()] == [12, 10, 13, 11]

    def test_build_index_is_idempotent_and_keeps_progress(self, archive_path):
        with CoverIndex(":memory:") as index:
            build_index(index, archive_path)
            index.mark(10, STATE_FILLED)
            build_index(index, archive_path)  # 重扫不能把进度冲掉
            assert index.counts()[STATE_FILLED] == 1
            assert [row[0] for row in index.pending()] == [12, 13, 11]

    def test_skips_title_too_long(self, tmp_path: Path):
        long_title = "长" * 501
        rows = [_row(20, 2, 0, long_title, "", {}), _row(21, 2, 0, "ok", "", {})]
        path = _write_archive(tmp_path / "long.zip", rows)
        with CoverIndex(":memory:") as index:
            stats = build_index(index, path)
            assert stats["skipped_long_title"] == 1
            assert index.counts()[STATE_PENDING] == 1

    def test_pending_limit_and_error_retry(self, archive_path):
        with CoverIndex(":memory:") as index:
            build_index(index, archive_path)
            index.mark(12, STATE_ERROR)
            assert [row[0] for row in index.pending(limit=2)] == [10, 13]
            assert [row[0] for row in index.pending(include_error=True)][0] == 12

    def test_archive_order(self, archive_path):
        with CoverIndex(":memory:") as index:
            build_index(index, archive_path)
            assert [row[0] for row in index.pending(order="archive")] == [10, 11, 12, 13]


class TestRunBackfill:
    def _config(self) -> SyncConfig:
        return SyncConfig(batch_size=2, timeout_seconds=1.0, max_attempts=1)

    def _seeded_index(self, archive_path: str, out_dir: Path) -> str:
        path = str(out_dir / "cover-index.sqlite")
        with CoverIndex(path) as index:
            build_index(index, archive_path)
        return path

    def test_dry_run_writes_nothing_and_keeps_state(self, archive_path, tmp_path):
        index_path = self._seeded_index(archive_path, tmp_path)
        client = FakeCoverClient(
            {"12": ("https://i/12.jpg", REASON_OK), "10": (None, REASON_NOT_FOUND)}
        )
        report = run_backfill(
            self._config(),
            apply=False,
            index_path=index_path,
            report_dir=str(tmp_path),
            cover_client=client,
            sleep=lambda _s: None,
        )
        assert report.processed == 4
        assert report.filled == 1  # 只有 12 有图（其余默认 NO_IMAGES）
        assert report.missing == 2  # 11、13
        assert report.not_found == 1  # 10
        assert report.delivered_items == 0
        with CoverIndex(index_path) as index:
            # 预演不改状态：下次真跑还要能再问一遍
            assert index.counts()[STATE_PENDING] == 4

    def test_apply_submits_and_marks_filled(self, archive_path, tmp_path):
        index_path = self._seeded_index(archive_path, tmp_path)
        client = FakeCoverClient(
            {
                "12": ("https://i/12.jpg", REASON_OK),
                "10": ("https://i/10.jpg", REASON_OK),
                "13": ("https://i/13.jpg", REASON_OK),
            }
        )
        importer = FakeImporter()
        report = run_backfill(
            self._config(),
            apply=True,
            index_path=index_path,
            report_dir=str(tmp_path),
            cover_client=client,
            importer=importer,
            sleep=lambda _s: None,
        )
        assert report.filled == 3
        assert report.delivered_items == 3
        assert len(importer.batches) == 2  # batch_size=2
        assert importer.batches[0]["source"] == SOURCE_BANGUMI
        with CoverIndex(index_path) as index:
            counts = index.counts()
            assert counts[STATE_FILLED] == 3
            # 4 条里 11 是「条目真没图」，标 missing 后也就不再重试了
            assert counts[STATE_PENDING] == 0
            assert counts[STATE_MISSING] == 1

    def test_payload_only_touches_cover(self, archive_path, tmp_path):
        """回填载荷必须是「四字段」，其余为 null——否则会把 summary/tags/rating 冲掉。"""
        index_path = self._seeded_index(archive_path, tmp_path)
        client = FakeCoverClient({"12": ("https://i/12.jpg", REASON_OK)})
        importer = FakeImporter()
        run_backfill(
            self._config(),
            apply=True,
            index_path=index_path,
            limit=1,
            report_dir=str(tmp_path),
            cover_client=client,
            importer=importer,
            sleep=lambda _s: None,
        )
        item = importer.batches[0]["items"][0]
        assert item["source_id"] == "12"
        assert item["work_type"] == "game"
        assert item["title"] == "时空轮回"
        assert item["cover_url"] == "https://i/12.jpg"
        assert item["source_url"] == "https://bgm.tv/subject/12"
        assert item["summary"] is None
        assert item["tags"] is None
        assert item["main_rating"] is None
        assert item["release_year"] is None

    def test_network_error_is_retried_later(self, archive_path, tmp_path):
        index_path = self._seeded_index(archive_path, tmp_path)
        client = FakeCoverClient({"12": (None, REASON_NETWORK)})
        report = run_backfill(
            self._config(),
            apply=True,
            index_path=index_path,
            limit=1,
            report_dir=str(tmp_path),
            cover_client=client,
            importer=FakeImporter(),
            sleep=lambda _s: None,
        )
        assert report.errors == 1
        with CoverIndex(index_path) as index:
            assert index.counts()[STATE_ERROR] == 1
            # 下一次带 --cover-retry-failed 才该再问它
            assert [row[0] for row in index.pending()] == [10, 13, 11]

    def test_report_is_written(self, archive_path, tmp_path):
        index_path = self._seeded_index(archive_path, tmp_path)
        run_backfill(
            self._config(),
            apply=False,
            index_path=index_path,
            report_dir=str(tmp_path),
            cover_client=FakeCoverClient({}),
            sleep=lambda _s: None,
        )
        reports = list(tmp_path.glob("cover-run-*.json"))
        assert len(reports) == 1
        data = json.loads(reports[0].read_text(encoding="utf-8"))
        assert data["dry_run"] is True
        assert data["total_indexed"] == 4

    def test_workers_keep_index_consistent(self, archive_path, tmp_path):
        """并发窗口只影响请求并发，索引写入必须在主线程且不漏行。"""
        index_path = self._seeded_index(archive_path, tmp_path)
        client = FakeCoverClient(
            {
                "12": ("https://i/12.jpg", REASON_OK),
                "10": ("https://i/10.jpg", REASON_OK),
                "13": ("https://i/13.jpg", REASON_OK),
                "11": ("https://i/11.jpg", REASON_OK),
            }
        )
        importer = FakeImporter()
        report = run_backfill(
            self._config(),
            apply=True,
            index_path=index_path,
            report_dir=str(tmp_path),
            cover_client=client,
            importer=importer,
            workers=4,
            sleep=lambda _s: None,
        )
        assert report.processed == 4
        assert report.filled == 4
        assert report.delivered_items == 4
        with CoverIndex(index_path) as index:
            assert index.counts()[STATE_FILLED] == 4
            assert index.counts()[STATE_PENDING] == 0

    def test_limit_caps_requests(self, archive_path, tmp_path):
        index_path = self._seeded_index(archive_path, tmp_path)
        client = FakeCoverClient({})
        run_backfill(
            self._config(),
            apply=False,
            index_path=index_path,
            limit=2,
            report_dir=str(tmp_path),
            cover_client=client,
            sleep=lambda _s: None,
        )
        assert client.asked == ["12", "10"]  # 热度前二

    def test_summary_mentions_dry_run(self, archive_path, tmp_path):
        index_path = self._seeded_index(archive_path, tmp_path)
        report = run_backfill(
            self._config(),
            apply=False,
            index_path=index_path,
            report_dir=str(tmp_path),
            cover_client=FakeCoverClient({}),
            sleep=lambda _s: None,
        )
        text = summarize(report)
        assert "预演" in text
        assert "4" in text


def test_default_settings_stay_inside_the_stable_envelope():
    """默认档位是「8 并发 + 0.25s 间隔」：实测 8–12 并发稳定，>12 会 429。

    这两个数被写进测试，是为了让「手滑调大一点」必须先改测试并说明理由——
    图床是别人的公共服务，把并发开到 32 只会换来 429 和断连，比串行还慢。
    """
    assert DEFAULT_COVER_INTERVAL_SECONDS == 0.25
    assert DEFAULT_COVER_WORKERS == 8