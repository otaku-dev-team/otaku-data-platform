"""把数据集里的资讯提交到后端（`POST /internal/import/articles`）。

与 `publisher.py`（作品）平行而不合并，理由和那边一致：三条导入端点的字段、
校验、合并逻辑都不同，合成一个会让报告分不清是哪一侧的问题。

## 本文件唯一的硬约束

**`related_work_ids` 里必须是 bangumi subject id**，不是站点的 content_id。

数据集的 `article_links` 由导出 SQL 直接 JOIN 出 `bangumi_id`
（见 `otaku-bangumi.json` 的 `article_links.query`），所以这里不做二次映射。
但如果喂进来的是 `otaku.json` 那套映射（`work_source_id` = content_id），
写进后端就是两套号混用——表现不是报错，而是「关联作品全空」或「串到别的作品」。
两套号都是纯数字，无法从值上区分，所以这里用**覆盖率自查**兜底：
`article_links.work_source_id` 命中 `works.source_id` 的比例过低时明确警告。

## 默认预演

与 `publish_dataset` 一致：`apply=False` 只读数据集、只统计、不发请求。
"""

from __future__ import annotations

import json
import sqlite3
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator, Sequence

from ..config import SOURCE_NAME
from ..models import ArticleItem, SourceRecord
from .exporter import assert_compatible
from .publisher import CHUNK_LIMIT, make_batch_id

#: 关联命中率低于这个值就警告（正常应在 90% 以上；0% 通常意味着号域错了）
LINK_HIT_RATE_WARN = 0.5

#: 资讯行的 `source` 固定 `otaku_site`（后端 V9：`uk_article_source(source, source_id)`，
#: `ArticleImportService.DEFAULT_SOURCE` 也是它）。
#: **不能**跟随数据集的 `backend_source`（那是 `bangumi`，作品行的来源标识）——
#: 换了 source 同一篇资讯会被当成新行再插一遍，目录翻倍且不报错。
ARTICLE_SOURCE = SOURCE_NAME


@dataclass
class ArticlePublishReport:
    dataset_path: str
    backend_source: str
    fetched_at: str
    dry_run: bool
    article_source: str = ARTICLE_SOURCE
    articles_scanned: int = 0
    items_built: int = 0
    links_total: int = 0
    links_matched: int = 0
    articles_with_links: int = 0
    batches: list[dict[str, Any]] = field(default_factory=list)
    counts: dict[str, int] = field(default_factory=dict)
    errors: list[Any] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    aborted: str | None = None
    elapsed_seconds: float = 0.0

    @property
    def ok(self) -> bool:
        return not self.aborted and not self.errors

    @property
    def link_hit_rate(self) -> float:
        return self.links_matched / self.links_total if self.links_total else 0.0

    def to_dict(self) -> dict[str, Any]:
        return {
            "dataset_path": self.dataset_path,
            "backend_source": self.backend_source,
            "article_source": self.article_source,
            "fetched_at": self.fetched_at,
            "dry_run": self.dry_run,
            "articles_scanned": self.articles_scanned,
            "items_built": self.items_built,
            "links_total": self.links_total,
            "links_matched": self.links_matched,
            "link_hit_rate": round(self.link_hit_rate, 4),
            "articles_with_links": self.articles_with_links,
            "batches": self.batches,
            "counts": self.counts,
            "errors": self.errors,
            "warnings": self.warnings,
            "aborted": self.aborted,
            "elapsed_seconds": round(self.elapsed_seconds, 3),
        }


def _connect(dataset_path: str | Path) -> sqlite3.Connection:
    conn = sqlite3.connect(f"file:{dataset_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def _links_for(conn: sqlite3.Connection, article_ids: Sequence[str]) -> dict[str, list[str]]:
    """一次 `IN` 取回这批文章的关联作品 id，禁止逐条查（N+1）。"""
    if not article_ids:
        return {}
    placeholders = ",".join("?" for _ in article_ids)
    rows = conn.execute(
        f"SELECT article_source_id, work_source_id FROM article_links"
        f" WHERE article_source_id IN ({placeholders})"
        f" ORDER BY article_source_id, work_source_id",
        list(article_ids),
    )
    out: dict[str, list[str]] = {}
    for row in rows:
        out.setdefault(row["article_source_id"], []).append(row["work_source_id"])
    return out


def _link_coverage(conn: sqlite3.Connection, report: ArticlePublishReport) -> None:
    """号域自查：`article_links.work_source_id` 与 `works.source_id` 是否同域。

    两个号都是纯数字，值上分不出来，只能统计命中率。命中率极低说明导出时
    没做 content_id → bangumi_id 的 JOIN，这批数据不该发给后端。
    """
    try:
        total, matched = conn.execute(
            "SELECT COUNT(*),"
            " SUM(CASE WHEN EXISTS (SELECT 1 FROM works w"
            "                        WHERE w.source_id = al.work_source_id)"
            "     THEN 1 ELSE 0 END)"
            " FROM article_links al"
        ).fetchone()
    except sqlite3.OperationalError:
        report.warnings.append(
            "数据集里没有 works 表，跳过关联号域校验（无法确认 subject_id 是否可解析）。"
        )
        return
    report.links_total = int(total or 0)
    report.links_matched = int(matched or 0)
    report.articles_with_links = int(
        conn.execute("SELECT COUNT(DISTINCT article_source_id) FROM article_links").fetchone()[0] or 0
    )
    if report.links_total and report.link_hit_rate < LINK_HIT_RATE_WARN:
        report.warnings.append(
            f"关联命中率只有 {report.link_hit_rate:.1%}"
            f"（{report.links_matched}/{report.links_total} 命中 works.source_id）。"
            f"这通常意味着 article_links 里存的是 content_id 而不是 bangumi subject_id，"
            f"检查导出映射的 article_links.query 是否做了 JOIN contents.bangumi_id。"
        )


def _iter_article_chunks(
    conn: sqlite3.Connection,
    chunk_size: int,
    article_source: str,
    report: ArticlePublishReport,
) -> Iterator[list[ArticleItem]]:
    """按 source_id 排序分块产出（稳定排序 = 重跑时批次成员不变）。"""
    cur = conn.execute(
        "SELECT source_id, title, summary, body, category, published_at,"
        " source_name, source_url, cover_url"
        " FROM articles ORDER BY source_id"
    )
    batch: list[ArticleItem] = []
    while True:
        rows = cur.fetchmany(chunk_size)
        if not rows:
            break
        report.articles_scanned += len(rows)
        ids = [row["source_id"] for row in rows]
        links = _links_for(conn, ids)
        for row in rows:
            batch.append(
                ArticleItem(
                    source_record=SourceRecord(
                        source_id=row["source_id"],
                        source=article_source,
                    ),
                    title=row["title"],
                    summary=row["summary"],
                    body=row["body"],
                    category=row["category"],
                    published_at=row["published_at"],
                    source_name=row["source_name"],
                    # 这一列是「原文链接」（如 ln-news.com），不是站点资讯页
                    source_url=row["source_url"],
                    cover_url=row["cover_url"],
                    tags=None,
                    related_work_ids=links.get(row["source_id"]),
                )
            )
        while len(batch) >= chunk_size:
            chunk = batch[:chunk_size]
            del batch[:chunk_size]
            yield chunk
    if batch:
        yield batch


def publish_articles(
    dataset_path: str | Path,
    *,
    backend_source: str,
    chunk_size: int = CHUNK_LIMIT,
    limit: int | None = None,
    apply: bool = False,
    importer: Any | None = None,
    report_path: str | Path | None = None,
) -> ArticlePublishReport:
    """把数据集里的资讯提交到后端。默认预演，`apply=True` 才真的发。

    `importer` 只需提供 `submit_article_batch(batch_id, items, fetched_at, source)`；
    测试里给假对象即可，不必起后端。
    """
    started = time.time()
    if chunk_size < 1 or chunk_size > CHUNK_LIMIT:
        raise ValueError(f"chunk_size 必须在 1–{CHUNK_LIMIT} 之间，实际 {chunk_size}")

    meta = assert_compatible(dataset_path)
    fetched_at = meta.get("generated_at") or datetime.now(timezone.utc).isoformat(
        timespec="seconds"
    )
    report = ArticlePublishReport(
        dataset_path=str(dataset_path),
        backend_source=backend_source,
        fetched_at=fetched_at,
        dry_run=not apply,
    )
    if backend_source != ARTICLE_SOURCE:
        report.warnings.append(
            f"数据集的 backend_source={backend_source!r} 只用于报告；"
            f"资讯行的 source 固定 {ARTICLE_SOURCE!r}（唯一键 uk_article_source）。"
        )

    if apply and importer is None:
        raise ValueError("apply=True 时必须提供 importer")

    conn = _connect(dataset_path)
    remaining = limit
    try:
        _link_coverage(conn, report)
        for index, chunk in enumerate(
            _iter_article_chunks(conn, chunk_size, report.article_source, report)
        ):
            if remaining is not None:
                if remaining <= 0:
                    break
                chunk = chunk[:remaining]
                remaining -= len(chunk)
            payloads = [item.to_payload() for item in chunk]
            batch_id = make_batch_id("articles", index, payloads)
            report.items_built += len(chunk)

            if not apply:
                report.batches.append({"batch_id": batch_id, "items": len(chunk)})
                continue

            try:
                result = importer.submit_article_batch(
                    batch_id, chunk, fetched_at, source=report.article_source
                )
            except Exception as exc:  # noqa: BLE001 - 交付层异常一律中止，不硬发
                report.aborted = f"{type(exc).__name__}: {exc}"
                break

            report.batches.append(
                {
                    "batch_id": batch_id,
                    "items": len(chunk),
                    "counts": dict(result.counts),
                }
            )
            for key, value in result.counts.items():
                report.counts[key] = report.counts.get(key, 0) + value
            for err in result.errors:
                if len(report.errors) < 50:
                    report.errors.append(err)
    finally:
        conn.close()

    report.elapsed_seconds = time.time() - started
    if report.aborted:
        report.warnings.append(
            "已中止。重跑同一命令即可从断点继续：已成功批次 batch_id 不变，"
            "后端返回首次结果，不会重复入库。"
        )
    if not apply and report.items_built:
        report.warnings.append("这是预演，没有向后端发请求。确认无误后加 --apply 才写入。")

    if report_path is not None:
        rp = Path(report_path)
        rp.parent.mkdir(parents=True, exist_ok=True)
        rp.write_text(
            json.dumps(report.to_dict(), ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
    return report
