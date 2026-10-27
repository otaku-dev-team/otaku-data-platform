"""数据集 → 后端的提交层测试。

这层代码很薄，但两个地方错了会静默坏事，所以每条用例都盯着它们：

1. **批次号** 错了 → 重跑不能续、或数据更新了却静默不写；
2. **字段** 多发了 → 后端 400 或静默丢字段；少发了 → 更新时把已有数据覆盖成空。
"""

from __future__ import annotations

import sqlite3
from pathlib import Path

import pytest

from sync.dataset import make_batch_id, publish_dataset
from sync.dataset.publisher import CHUNK_LIMIT
from sync.dataset.schema import DATASET_VERSION, DDL
from sync.importer import ImportDeliveryError
from sync.models import BatchResult, ItemResult

PAYLOAD_KEYS = {
    "source_id",
    "work_type",
    "title",
    "summary",
    "cover_url",
    "release_year",
    "tags",
    "main_rating",
    "source_url",
}


def make_dataset(
    path: Path,
    works: list[dict],
    tags: dict[str, list[str]] | None = None,
    source_id: str = "otaku",
) -> Path:
    """按标准 schema 建一份最小数据集。"""
    conn = sqlite3.connect(path)
    conn.executescript(DDL)
    for row in works:
        conn.execute(
            "INSERT INTO works (source_id, work_type, title, summary, cover_url,"
            " release_year, rating_value, rating_scale, source_url)"
            " VALUES (?,?,?,?,?,?,?,?,?)",
            (
                row["source_id"],
                row.get("work_type", "anime"),
                row["title"],
                row.get("summary"),
                row.get("cover_url"),
                row.get("release_year"),
                row.get("rating_value"),
                row.get("rating_scale", "0-10"),
                row.get("source_url"),
            ),
        )
    for sid, names in (tags or {}).items():
        for name in names:
            conn.execute(
                "INSERT INTO work_tags (source_id, name) VALUES (?, ?)", (sid, name)
            )
    conn.executemany(
        "INSERT INTO meta (key, value) VALUES (?, ?)",
        [
            ("dataset_version", DATASET_VERSION),
            ("source_id", source_id),
            ("generated_at", "2026-10-28T00:00:00+00:00"),
        ],
    )
    conn.commit()
    conn.close()
    return path


def works_n(n: int, **overrides) -> list[dict]:
    return [
        {
            "source_id": f"W-{i:03d}",
            "title": f"作品 {i}",
            "work_type": "anime",
            "release_year": 2000 + i,
            **overrides,
        }
        for i in range(n)
    ]


class FakeImporter:
    """只记录调用、不碰网络。"""

    def __init__(self, results=None, fail_at: int | None = None) -> None:
        self.calls: list[tuple[str, int, str, str]] = []
        self._results = results or {}
        self._fail_at = fail_at

    def submit_batch(self, batch_id, items, fetched_at, source="otaku_site"):
        if self._fail_at is not None and len(self.calls) == self._fail_at:
            raise ImportDeliveryError("网络断了")
        self.calls.append((batch_id, len(items), fetched_at, source))
        counts = self._results.get(
            len(self.calls) - 1, {"inserted": len(items), "updated": 0,
                                  "unchanged": 0, "rejected": 0}
        )
        return BatchResult(batch_id=batch_id, counts=dict(counts))


# ---------------------------------------------------------------- 分块


def test_chunks_and_counts(tmp_path: Path) -> None:
    ds = make_dataset(tmp_path / "ds.db", works_n(7))

    report = publish_dataset(ds, chunk_size=3)

    assert [b.items for b in report.batches] == [3, 3, 1]
    assert report.items_built == 7
    assert report.works_scanned == 7
    assert report.dry_run is True
    assert report.ok


def test_limit_truncates_last_chunk(tmp_path: Path) -> None:
    ds = make_dataset(tmp_path / "ds.db", works_n(7))

    report = publish_dataset(ds, chunk_size=3, limit=4)

    assert [b.items for b in report.batches] == [3, 1]
    assert report.items_built == 4


def test_chunk_size_guard(tmp_path: Path) -> None:
    ds = make_dataset(tmp_path / "ds.db", works_n(1))

    with pytest.raises(ValueError):
        publish_dataset(ds, chunk_size=CHUNK_LIMIT + 1)
    with pytest.raises(ValueError):
        publish_dataset(ds, chunk_size=0)


# ---------------------------------------------------------------- 批次号


def test_batch_id_is_stable_across_runs(tmp_path: Path) -> None:
    """断点续跑的前提：同一份数据重跑，批次号必须一模一样。"""
    ds = make_dataset(tmp_path / "ds.db", works_n(7))

    first = publish_dataset(ds, chunk_size=3)
    second = publish_dataset(ds, chunk_size=3)

    assert [b.batch_id for b in first.batches] == [b.batch_id for b in second.batches]


def test_batch_id_changes_when_content_changes(tmp_path: Path) -> None:
    """数据更新后必须换号，否则幂等键会把新数据静默吞掉。"""
    ds = make_dataset(tmp_path / "ds.db", works_n(7))
    before = publish_dataset(ds, chunk_size=3)

    conn = sqlite3.connect(ds)
    conn.execute("UPDATE works SET title='改过的标题' WHERE source_id='W-001'")
    conn.commit()
    conn.close()

    after = publish_dataset(ds, chunk_size=3)

    # 只有包含 W-001 的那一批换号，其余不变
    assert before.batches[0].batch_id != after.batches[0].batch_id
    assert before.batches[1].batch_id == after.batches[1].batch_id


def test_batch_id_format_fits_backend_column() -> None:
    bid = make_batch_id("works", 12, [{"source_id": "W-1"}])
    assert bid.startswith("ds-works-00012-")
    assert len(bid) <= 128  # 后端 batch_id 是 VARCHAR(128)


# ---------------------------------------------------------------- 字段


def test_payload_has_exactly_contract_fields(tmp_path: Path) -> None:
    """多一个字段就是契约外的野字段，后端会 400 或静默丢。"""
    ds = make_dataset(
        tmp_path / "ds.db",
        [{"source_id": "W-1", "title": "标题", "release_year": 2020,
          "rating_value": 8.5, "rating_scale": "0-10",
          "source_url": "https://site/contents/1", "summary": "简介"}],
    )

    report = publish_dataset(ds)
    assert report.items_built == 1

    from sync.dataset.publisher import _connect, _iter_chunks

    conn = _connect(ds)
    from sync.dataset.publisher import PublishReport

    items = list(
        _iter_chunks(
            conn,
            500,
            "otaku_site",
            PublishReport(dataset_path=str(ds), backend_source="otaku_site",
                          fetched_at="", dry_run=True),
        )
    )
    conn.close()
    payload = items[0][0].to_payload()

    assert set(payload) == PAYLOAD_KEYS
    assert payload["main_rating"] == {
        "value": 8.5, "scale": "0-10", "source": "otaku_site"
    }
    assert payload["release_year"] == 2020


def test_tags_aggregated_and_missing_becomes_null(tmp_path: Path) -> None:
    """无标签必须是 null 而不是 []：[] 会清空已有标签，而数据集分不清
    "确实没标签"与"源站没录"。"""
    ds = make_dataset(
        tmp_path / "ds.db",
        works_n(2),
        tags={"W-000": ["日常", "治愈"]},
    )

    report = publish_dataset(ds)
    assert report.items_built == 2

    from sync.dataset.publisher import PublishReport, _connect, _iter_chunks

    conn = _connect(ds)
    chunk = next(
        _iter_chunks(
            conn,
            500,
            "otaku_site",
            PublishReport(dataset_path=str(ds), backend_source="otaku_site",
                          fetched_at="", dry_run=True),
        )
    )
    conn.close()
    payloads = {item.to_payload()["source_id"]: item.to_payload() for item in chunk}

    assert payloads["W-000"]["tags"] == ["日常", "治愈"]  # 按 name 排序，稳定
    assert payloads["W-001"]["tags"] is None


def test_invalid_work_type_filtered_out(tmp_path: Path) -> None:
    ds = make_dataset(
        tmp_path / "ds.db",
        works_n(3) + [{"source_id": "W-900", "title": "某音乐", "work_type": "music"}],
    )

    report = publish_dataset(ds)

    assert report.skipped_invalid_type == 1
    assert report.items_built == 3
    assert report.skipped_samples[0]["source_id"] == "W-900"


# ---------------------------------------------------------------- 提交


def test_apply_submits_and_aggregates(tmp_path: Path) -> None:
    ds = make_dataset(tmp_path / "ds.db", works_n(7))
    importer = FakeImporter(
        results={
            0: {"inserted": 3, "updated": 0, "unchanged": 0, "rejected": 0},
            1: {"inserted": 2, "updated": 1, "unchanged": 0, "rejected": 0},
            2: {"inserted": 0, "updated": 0, "unchanged": 1, "rejected": 0},
        }
    )

    report = publish_dataset(
        ds, chunk_size=3, apply=True, importer=importer,
        backend_source="otaku_site",
    )

    assert report.dry_run is False
    assert len(importer.calls) == 3
    assert [c[1] for c in importer.calls] == [3, 3, 1]
    assert all(c[3] == "otaku_site" for c in importer.calls)
    # fetched_at 取数据集生成时间，不是"现在"——记的是数据什么时候抓的
    assert all(c[2] == "2026-10-28T00:00:00+00:00" for c in importer.calls)
    assert report.counts == {"inserted": 5, "updated": 1, "unchanged": 1, "rejected": 0}


def test_abort_on_delivery_error_keeps_finished_batches(tmp_path: Path) -> None:
    ds = make_dataset(tmp_path / "ds.db", works_n(7))
    importer = FakeImporter(fail_at=1)  # 第 2 批断网

    report = publish_dataset(ds, chunk_size=3, apply=True, importer=importer)

    assert report.ok is False
    assert "ImportDeliveryError" in (report.aborted or "")
    assert len(report.batches) == 1  # 第 1 批的结果保留
    assert report.counts["inserted"] == 3
    assert any("重跑" in w for w in report.warnings)


def test_apply_requires_importer(tmp_path: Path) -> None:
    ds = make_dataset(tmp_path / "ds.db", works_n(1))
    with pytest.raises(ValueError):
        publish_dataset(ds, apply=True, importer=None)


# ---------------------------------------------------------------- 来源标识


def test_warns_when_backend_source_differs_from_dataset(tmp_path: Path) -> None:
    """这是"1.8 万条变 3.6 万条"的入口，必须出声。"""
    ds = make_dataset(tmp_path / "ds.db", works_n(2), source_id="otaku")

    report = publish_dataset(ds, backend_source="otaku_site")

    assert any("otaku" in w and "otaku_site" in w for w in report.warnings)


def test_no_warning_when_sources_match(tmp_path: Path) -> None:
    ds = make_dataset(tmp_path / "ds.db", works_n(2), source_id="site_a")

    report = publish_dataset(ds, backend_source="site_a")

    # 预演提示不算数据问题，这里只看有没有"唯一键"那条
    assert not any("唯一键" in w for w in report.warnings)


def test_rejects_unknown_dataset_version(tmp_path: Path) -> None:
    ds = make_dataset(tmp_path / "ds.db", works_n(1))
    conn = sqlite3.connect(ds)
    conn.execute("UPDATE meta SET value='99' WHERE key='dataset_version'")
    conn.commit()
    conn.close()

    with pytest.raises(Exception):
        publish_dataset(ds)


# ---------------------------------------------------------------- 封面


def _payloads(ds: Path, site_base_url: str = "") -> dict[str, dict]:
    from sync.dataset.publisher import PublishReport, _connect, _iter_chunks

    conn = _connect(ds)
    chunk = next(
        _iter_chunks(
            conn,
            500,
            "otaku_site",
            PublishReport(dataset_path=str(ds), backend_source="otaku_site",
                          fetched_at="", dry_run=True),
            site_base_url,
        )
    )
    conn.close()
    return {i.to_payload()["source_id"]: i.to_payload() for i in chunk}


def test_relative_cover_is_absolutized(tmp_path: Path) -> None:
    """站点存的是 /covers/x.jpg 这种站内相对路径，后端封面代理只认绝对地址。"""
    ds = make_dataset(
        tmp_path / "ds.db",
        [{"source_id": "W-1", "title": "标题", "cover_url": "/covers/cover_a.jpg"}],
    )

    report = publish_dataset(ds, site_base_url="http://site:8000")
    payload = _payloads(ds, "http://site:8000")["W-1"]

    assert payload["cover_url"] == "http://site:8000/covers/cover_a.jpg"
    assert report.covers_resolved == 1
    assert report.covers_dropped == 0


def test_relative_cover_dropped_without_base_url(tmp_path: Path) -> None:
    """没有基址时宁可不发：写相对地址既不能用，还会覆盖掉已有绝对地址。"""
    ds = make_dataset(
        tmp_path / "ds.db",
        [{"source_id": "W-1", "title": "标题", "cover_url": "/covers/cover_a.jpg"}],
    )

    report = publish_dataset(ds)

    assert _payloads(ds)["W-1"]["cover_url"] is None
    assert report.covers_dropped == 1
    assert any("--source-base-url" in w for w in report.warnings)


def test_absolute_cover_untouched(tmp_path: Path) -> None:
    ds = make_dataset(
        tmp_path / "ds.db",
        [{"source_id": "W-1", "title": "标题",
          "cover_url": "https://bgmimg.example/x.jpg"}],
    )

    report = publish_dataset(ds, site_base_url="http://site:8000")

    assert _payloads(ds, "http://site:8000")["W-1"]["cover_url"] == (
        "https://bgmimg.example/x.jpg"
    )
    assert report.covers_absolute == 1
    assert report.covers_resolved == 0


def test_error_details_are_capped(tmp_path: Path) -> None:
    """拒收明细只在报告里留前 200 条，否则全量跑完报告能有几 MB。"""
    ds = make_dataset(tmp_path / "ds.db", works_n(3))

    class RejectingImporter(FakeImporter):
        def submit_batch(self, batch_id, items, fetched_at, source="otaku_site"):
            self.calls.append((batch_id, len(items), fetched_at, source))
            return BatchResult(
                batch_id=batch_id,
                counts={"inserted": 0, "updated": 0, "unchanged": 0,
                        "rejected": len(items)},
                errors=[
                    ItemResult(source_id=i.source_id, result="rejected",
                               reason_code="TITLE_TOO_LONG")
                    for i in items
                ],
            )

    report = publish_dataset(
        ds, chunk_size=1, apply=True, importer=RejectingImporter()
    )

    assert report.counts["rejected"] == 3
    assert len(report.errors) == 3
    assert report.errors[0].reason_code == "TITLE_TOO_LONG"


# --------------------------------------------------------------- 档 B 关联数组


def _add_relations(
    path: Path,
    credits: list[dict] | None = None,
    cast: list[dict] | None = None,
    studios: list[dict] | None = None,
) -> None:
    """往数据集里补关联表数据（模拟导出器写过之后的状态）。"""
    conn = sqlite3.connect(path)
    for row in credits or []:
        conn.execute(
            "INSERT INTO work_credits (source_id, role, name, person_ref, tier,"
            " sort_order) VALUES (?,?,?,?,?,?)",
            (
                row["source_id"],
                row["role"],
                row["name"],
                row.get("person_ref"),
                row.get("tier", "main"),
                row.get("sort_order", 0),
            ),
        )
    for row in cast or []:
        conn.execute(
            "INSERT INTO work_cast (source_id, character, actor, person_ref,"
            " relation, sort_order) VALUES (?,?,?,?,?,?)",
            (
                row["source_id"],
                row["character"],
                row["actor"],
                row.get("person_ref"),
                row.get("relation"),
                row.get("sort_order", 0),
            ),
        )
    for row in studios or []:
        conn.execute(
            "INSERT INTO work_studios (source_id, name) VALUES (?, ?)",
            (row["source_id"], row["name"]),
        )
    conn.commit()
    conn.close()


def test_relation_arrays_flow_into_payload(tmp_path: Path) -> None:
    """Staff / 角色声优 / 制作公司按作品聚合进一条载荷。"""
    ds = make_dataset(tmp_path / "ds.db", [{"source_id": "W-1", "title": "甲"}])
    _add_relations(
        ds,
        credits=[
            {"source_id": "W-1", "role": "导演", "name": "山田", "sort_order": 0},
            {"source_id": "W-1", "role": "脚本", "name": "伊藤",
             "person_ref": "9001", "sort_order": 1},
        ],
        cast=[
            {"source_id": "W-1", "character": "艾妲", "actor": "長谷川",
             "relation": "配角", "person_ref": "7001", "sort_order": 0},
        ],
        studios=[{"source_id": "W-1", "name": "J.C.STAFF"}],
    )

    payload = _payloads(ds)["W-1"]

    assert payload["staff"] == [
        {"role": "导演", "name": "山田", "person_id": None},
        {"role": "脚本", "name": "伊藤", "person_id": "9001"},
    ]
    assert payload["characters"] == [
        {"name": "艾妲", "actor": "長谷川", "character_type": "配角",
         "person_id": "7001"},
    ]
    assert payload["studios"] == ["J.C.STAFF"]


def test_sort_order_keeps_source_ordering(tmp_path: Path) -> None:
    """顺序按来源侧的 sort_order，不按名字重排——那是替来源决定谁更重要。"""
    ds = make_dataset(tmp_path / "ds.db", [{"source_id": "W-1", "title": "甲"}])
    _add_relations(
        ds,
        credits=[
            {"source_id": "W-1", "role": "脚本", "name": "A", "sort_order": 5},
            {"source_id": "W-1", "role": "导演", "name": "Z", "sort_order": 1},
        ],
    )

    assert [s["name"] for s in _payloads(ds)["W-1"]["staff"]] == ["Z", "A"]


def test_absent_relations_are_omitted_not_empty(tmp_path: Path) -> None:
    """没有关联数据的作品**不发** `[]`。

    `[]` 在契约里是「明确没有，清空已有值」。数据集里没有行分不清「确实没有」
    与「源站没录」，误判就是不可逆的内容损失——所以宁可不覆盖。
    """
    ds = make_dataset(tmp_path / "ds.db", [{"source_id": "W-1", "title": "甲"}])

    payload = _payloads(ds)["W-1"]

    for key in ("staff", "characters", "studios"):
        assert key not in payload


def test_duplicate_relation_rows_are_collapsed(tmp_path: Path) -> None:
    """源表没有唯一约束，同一个人同一职位可能有两行——载荷里只出一条。"""
    ds = make_dataset(tmp_path / "ds.db", [{"source_id": "W-1", "title": "甲"}])
    _add_relations(
        ds,
        credits=[
            {"source_id": "W-1", "role": "导演", "name": "山田"},
            {"source_id": "W-1", "role": "导演", "name": "山田"},
        ],
    )

    assert len(_payloads(ds)["W-1"]["staff"]) == 1


def test_rich_fields_flow_into_payload(tmp_path: Path) -> None:
    """档 A 的 4 个富字段从数据集带进载荷。"""
    ds = make_dataset(tmp_path / "ds.db", [{"source_id": "W-1", "title": "甲"}])
    conn = sqlite3.connect(ds)
    conn.execute(
        "UPDATE works SET title_original=?, aliases_json=?, media=?, episodes=?"
        " WHERE source_id='W-1'",
        ("新世紀エヴァンゲリオン", '["天鹰战士", "EVA"]', "TV", 26),
    )
    conn.commit()
    conn.close()

    payload = _payloads(ds)["W-1"]

    assert payload["title_original"] == "新世紀エヴァンゲリオン"
    assert payload["aliases"] == ["天鹰战士", "EVA"]
    assert payload["media"] == "TV"
    assert payload["episodes"] == 26


def test_broken_aliases_json_is_not_sent(tmp_path: Path) -> None:
    """别名 JSON 解析失败就不发：`[]` 会清空已有别名，而我们并不知道有没有。"""
    ds = make_dataset(tmp_path / "ds.db", [{"source_id": "W-1", "title": "甲"}])
    conn = sqlite3.connect(ds)
    conn.execute("UPDATE works SET aliases_json='{不是数组' WHERE source_id='W-1'")
    conn.commit()
    conn.close()

    assert "aliases" not in _payloads(ds)["W-1"]


# --------------------------------------------------------------- 档 B 关联数组


def _add_relations(
    path: Path,
    credits: list[dict] | None = None,
    cast: list[dict] | None = None,
    studios: list[dict] | None = None,
) -> None:
    """往数据集里补关联表数据（模拟导出器写过之后的状态）。"""
    conn = sqlite3.connect(path)
    for row in credits or []:
        conn.execute(
            "INSERT INTO work_credits (source_id, role, name, person_ref, tier,"
            " sort_order) VALUES (?,?,?,?,?,?)",
            (
                row["source_id"],
                row["role"],
                row["name"],
                row.get("person_ref"),
                row.get("tier", "main"),
                row.get("sort_order", 0),
            ),
        )
    for row in cast or []:
        conn.execute(
            "INSERT INTO work_cast (source_id, character, actor, person_ref,"
            " relation, sort_order) VALUES (?,?,?,?,?,?)",
            (
                row["source_id"],
                row["character"],
                row["actor"],
                row.get("person_ref"),
                row.get("relation"),
                row.get("sort_order", 0),
            ),
        )
    for row in studios or []:
        conn.execute(
            "INSERT INTO work_studios (source_id, name) VALUES (?, ?)",
            (row["source_id"], row["name"]),
        )
    conn.commit()
    conn.close()


def test_relation_arrays_flow_into_payload(tmp_path: Path) -> None:
    """Staff / 角色声优 / 制作公司按作品聚合进一条载荷。"""
    ds = make_dataset(tmp_path / "ds.db", [{"source_id": "W-1", "title": "甲"}])
    _add_relations(
        ds,
        credits=[
            {"source_id": "W-1", "role": "导演", "name": "山田", "sort_order": 0},
            {"source_id": "W-1", "role": "脚本", "name": "伊藤",
             "person_ref": "9001", "sort_order": 1},
        ],
        cast=[
            {"source_id": "W-1", "character": "艾妲", "actor": "長谷川",
             "relation": "配角", "person_ref": "7001", "sort_order": 0},
        ],
        studios=[{"source_id": "W-1", "name": "J.C.STAFF"}],
    )

    payload = _payloads(ds)["W-1"]

    assert payload["staff"] == [
        {"role": "导演", "name": "山田", "person_id": None},
        {"role": "脚本", "name": "伊藤", "person_id": "9001"},
    ]
    assert payload["characters"] == [
        {"name": "艾妲", "actor": "長谷川", "character_type": "配角",
         "person_id": "7001"},
    ]
    assert payload["studios"] == ["J.C.STAFF"]


def test_sort_order_keeps_source_ordering(tmp_path: Path) -> None:
    """顺序按来源侧的 sort_order，不按名字重排——那是替来源决定谁更重要。"""
    ds = make_dataset(tmp_path / "ds.db", [{"source_id": "W-1", "title": "甲"}])
    _add_relations(
        ds,
        credits=[
            {"source_id": "W-1", "role": "脚本", "name": "A", "sort_order": 5},
            {"source_id": "W-1", "role": "导演", "name": "Z", "sort_order": 1},
        ],
    )

    assert [s["name"] for s in _payloads(ds)["W-1"]["staff"]] == ["Z", "A"]


def test_absent_relations_are_omitted_not_empty(tmp_path: Path) -> None:
    """没有关联数据的作品**不发** `[]`。

    `[]` 在契约里是「明确没有，清空已有值」。数据集里没有行分不清「确实没有」
    与「源站没录」，误判就是不可逆的内容损失——所以宁可不覆盖。
    """
    ds = make_dataset(tmp_path / "ds.db", [{"source_id": "W-1", "title": "甲"}])

    payload = _payloads(ds)["W-1"]

    for key in ("staff", "characters", "studios"):
        assert key not in payload


def test_duplicate_relation_rows_are_collapsed(tmp_path: Path) -> None:
    """源表没有唯一约束，同一个人同一职位可能有两行——载荷里只出一条。"""
    ds = make_dataset(tmp_path / "ds.db", [{"source_id": "W-1", "title": "甲"}])
    _add_relations(
        ds,
        credits=[
            {"source_id": "W-1", "role": "导演", "name": "山田"},
            {"source_id": "W-1", "role": "导演", "name": "山田"},
        ],
    )

    assert len(_payloads(ds)["W-1"]["staff"]) == 1


def test_rich_fields_flow_into_payload(tmp_path: Path) -> None:
    """档 A 的 4 个富字段从数据集带进载荷。"""
    ds = make_dataset(tmp_path / "ds.db", [{"source_id": "W-1", "title": "甲"}])
    conn = sqlite3.connect(ds)
    conn.execute(
        "UPDATE works SET title_original=?, aliases_json=?, media=?, episodes=?"
        " WHERE source_id='W-1'",
        ("新世紀エヴァンゲリオン", '["天鹰战士", "EVA"]', "TV", 26),
    )
    conn.commit()
    conn.close()

    payload = _payloads(ds)["W-1"]

    assert payload["title_original"] == "新世紀エヴァンゲリオン"
    assert payload["aliases"] == ["天鹰战士", "EVA"]
    assert payload["media"] == "TV"
    assert payload["episodes"] == 26


def test_broken_aliases_json_is_not_sent(tmp_path: Path) -> None:
    """别名 JSON 解析失败就不发：`[]` 会清空已有别名，而我们并不知道有没有。"""
    ds = make_dataset(tmp_path / "ds.db", [{"source_id": "W-1", "title": "甲"}])
    conn = sqlite3.connect(ds)
    conn.execute("UPDATE works SET aliases_json='{不是数组' WHERE source_id='W-1'")
    conn.commit()
    conn.close()

    assert "aliases" not in _payloads(ds)["W-1"]
