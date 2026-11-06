"""资讯发布（数据集 → `/internal/import/articles`）的测试。

这层盯三件会**静默**坏事的事：

1. `related_work_ids` 必须原样透传（不能丢，也不能偷偷换成 content_id）；
2. 资讯行的 `source` 必须是 `otaku_site` —— 跟作品的 `backend_source`（`bangumi`）
   串了，同一篇会被当成新行再插一遍，目录翻倍且不报错；
3. 号域不对时（把 content_id 当 subject_id 喂进来）要给警告，而不是静默发。
"""

from __future__ import annotations

import sqlite3
from pathlib import Path

from sync.dataset import publish_articles
from sync.dataset.schema import DATASET_VERSION, DDL


def make_dataset(
    path: Path,
    articles: list[dict],
    links: list[tuple[str, str]],
    works: tuple[str, ...] = ("8", "7556"),
    source_id: str = "otaku",
) -> Path:
    """按标准 schema 建一份最小数据集（只填资讯发布用得到的表）。"""
    conn = sqlite3.connect(path)
    conn.executescript(DDL)
    for work_source_id in works:
        conn.execute(
            "INSERT INTO works (source_id, work_type, title) VALUES (?,?,?)",
            (work_source_id, "anime", f"作品 {work_source_id}"),
        )
    for article in articles:
        conn.execute(
            "INSERT INTO articles (source_id, title, summary, body, published_at)"
            " VALUES (?,?,?,?,?)",
            (
                article["id"],
                article["title"],
                article.get("summary"),
                article.get("body"),
                article.get("published_at", "2026-11-01T00:00:00+00:00"),
            ),
        )
    for article_id, work_source_id in links:
        conn.execute(
            "INSERT INTO article_links (article_source_id, work_source_id) VALUES (?,?)",
            (article_id, work_source_id),
        )
    conn.executemany(
        "INSERT INTO meta (key, value) VALUES (?, ?)",
        [
            ("dataset_version", DATASET_VERSION),
            ("source_id", source_id),
            ("generated_at", "2026-11-05T00:00:00+00:00"),
        ],
    )
    conn.commit()
    conn.close()
    return path


class FakeImporter:
    """只记录调用，不碰网络。"""

    def __init__(self) -> None:
        self.calls: list[dict] = []

    def submit_article_batch(self, batch_id, items, fetched_at, source="otaku_site"):
        self.calls.append(
            {
                "batch_id": batch_id,
                "source": source,
                "items": [item.to_payload() for item in items],
            }
        )

        class _Result:
            counts = {"inserted": len(items)}
            errors: list = []

        return _Result()


def test_dry_run_passes_links_through(tmp_path: Path) -> None:
    dataset = make_dataset(
        tmp_path / "ds.db",
        articles=[{"id": "339", "title": "新番情报"}, {"id": "340", "title": "无关联"}],
        links=[("339", "7556"), ("339", "8")],
    )

    report = publish_articles(dataset, backend_source="bangumi", chunk_size=10)

    assert report.items_built == 2
    assert report.articles_with_links == 1
    assert report.links_total == 2
    assert report.links_matched == 2  # 两个都在 works 里
    assert report.link_hit_rate == 1.0
    # 预演不发请求
    assert report.dry_run is True
    assert report.batches


def test_links_reach_payload_in_order(tmp_path: Path) -> None:
    dataset = make_dataset(
        tmp_path / "ds.db",
        articles=[{"id": "339", "title": "新番情报"}],
        links=[("339", "7556"), ("339", "8")],
    )
    importer = FakeImporter()

    publish_articles(
        dataset, backend_source="bangumi", chunk_size=10, apply=True, importer=importer
    )

    payload = importer.calls[0]["items"][0]
    # 顺序按 work_source_id 升序稳定输出（"7556" < "8" 是字典序）
    assert payload["related_work_ids"] == ["7556", "8"]


def test_source_is_otaku_site_even_when_backend_source_is_bangumi(tmp_path: Path) -> None:
    """作品的 backend_source 是 bangumi，但资讯行的 source 必须是 otaku_site。"""
    dataset = make_dataset(
        tmp_path / "ds.db",
        articles=[{"id": "339", "title": "新番情报"}],
        links=[],
    )
    importer = FakeImporter()

    report = publish_articles(
        dataset, backend_source="bangumi", chunk_size=10, apply=True, importer=importer
    )

    assert importer.calls[0]["source"] == "otaku_site"
    assert report.article_source == "otaku_site"
    # 数据集标识与资讯 source 不同，必须提醒一句
    assert any("backend_source" in w for w in report.warnings)


def test_wrong_id_space_warns(tmp_path: Path) -> None:
    """把 content_id 当 subject_id 喂进来：命中率 0，必须告警。"""
    dataset = make_dataset(
        tmp_path / "ds.db",
        articles=[{"id": "339", "title": "新番情报"}],
        links=[("339", "12345"), ("339", "67890")],  # 都不在 works 里
    )

    report = publish_articles(dataset, backend_source="bangumi", chunk_size=10)

    assert report.links_matched == 0
    assert report.link_hit_rate == 0.0
    assert any("关联命中率" in w for w in report.warnings)


def test_batch_id_is_stable_across_runs(tmp_path: Path) -> None:
    dataset = make_dataset(
        tmp_path / "ds.db",
        articles=[{"id": str(i), "title": f"资讯 {i}"} for i in range(5)],
        links=[],
    )

    first = publish_articles(dataset, backend_source="bangumi", chunk_size=2)
    second = publish_articles(dataset, backend_source="bangumi", chunk_size=2)

    assert [b["batch_id"] for b in first.batches] == [b["batch_id"] for b in second.batches]
    assert len(first.batches) == 3


def test_limit_caps_items(tmp_path: Path) -> None:
    dataset = make_dataset(
        tmp_path / "ds.db",
        articles=[{"id": str(i), "title": f"资讯 {i}"} for i in range(5)],
        links=[],
    )

    report = publish_articles(dataset, backend_source="bangumi", chunk_size=2, limit=3)

    assert report.items_built == 3
