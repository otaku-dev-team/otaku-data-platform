"""封面回填：给 `source='bangumi'` 的作品补上封面来源地址。

## 为什么单独一个作业（docs/data-completeness-plan.md §3）

bangumi 这 55.6 万条来自官方档案快照的 `subject.jsonlines`，**该档案不含 `images` 字段**
（上游就没给，不是入库时弄丢了），所以常规导入只能把 `cover_url` 写成 `None`。
补封面必须回上游按 id 逐条取，是「一条一次网络请求」的长尾作业，节奏和批量导入完全不同，
故独立成子命令。

## 为什么不新增后端接口

`WorkMerger` 的更新语义是「只覆盖本次出现且非 null 的字段」，且封面变化会自动清掉
本地缓存键（下次访问强制重新回源）。因此本作业每次只提交
`source_id` / `work_type` / `title` / `cover_url` 四个字段，其余字段一律 null = 保留原值。
这样**复用接口②，后端零改动、契约零变更**，也不会把 summary / tags / rating 冲掉。

## 图链尺寸顺序（2026-10-19 实测修正，与 §4.4 初稿相反）

`COVER_SIZE_PREFERENCE` 是 large → common → medium。初稿写的是 common 优先（列表缩略图
更省流量），但实测镜像图床 `bgmimg.anibt.net` **只放行原图路径**，`/r/800/`、`/r/400/`
这类缩略路径一律 403——按 common 优先跑，每条都拿到 403，线上 4449 部作品长期没封面
就是这么踩出来的。large 原图约 200KB，到站后由后端 `/api/covers/{id}` 落盘缓存再对外，
多花一次带宽换「每张图都真下得来」。

## 索引与断点续跑

56 万条 × 1 req/s 是按天计的作业，进程一定会被打断（部署、维护、限流退避）。
所以进度不放在内存或报告文件里，而是落一个 sqlite 索引（默认 `cover-index.sqlite`）：
建索引时把「id / 类型 / 标题 / 热度」一次性落盘，之后每条处理完就地改状态
（`pending` → `filled` / `missing` / `error`）。重跑从 `pending` 继续，
**已完成的绝不重复请求、绝不重复写入**，天然幂等；`filled` 的行不会被再次覆盖。

## 处理顺序

默认按热度降序（`favorite` 各状态计数之和），让首页 / 搜索最可能被点到的作品先有图。
全量跑完是以天计的事，先有图的应该是最该有图的那批。
"""

from __future__ import annotations

import json
import os
import sqlite3
import threading
import time
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from dataclasses import dataclass, field
from typing import Any, Iterable, Sequence

import httpx
from tenacity import Retrying, retry_if_exception_type, stop_after_attempt, wait_fixed

from .bangumi import SUBJECT_URL, iter_subjects, map_work_type, pick_title
from .config import SOURCE_BANGUMI, SyncConfig
from .importer import JavaImporter
from .models import SourceRecord, WorkItem, utc_now

#: 取图链接的尺寸优先级。理由见模块文档（large 原图优先，镜像只放行原图）。
COVER_SIZE_PREFERENCE = ("large", "common", "medium")

#: 与后端 `ImportItemValidator.MAX_TITLE_LENGTH` 一致；超长的档案条目本来就没能入库，
#: 这里在建索引阶段就跳过，不为它们白花一次上游请求。
MAX_TITLE_LENGTH = 500

STATE_PENDING = "pending"
STATE_FILLED = "filled"
STATE_MISSING = "missing"
STATE_ERROR = "error"
VALID_STATES = (STATE_PENDING, STATE_FILLED, STATE_MISSING, STATE_ERROR)

REASON_OK = "OK"
REASON_NOT_FOUND = "NOT_FOUND"
REASON_NO_IMAGES = "NO_IMAGES"
REASON_NETWORK = "NETWORK_ERROR"

_SCHEMA = """
CREATE TABLE IF NOT EXISTS subject (
    id          INTEGER PRIMARY KEY,
    work_type   TEXT    NOT NULL,
    title       TEXT    NOT NULL,
    popularity  INTEGER NOT NULL DEFAULT 0,
    state       TEXT    NOT NULL DEFAULT 'pending',
    cover_url   TEXT,
    updated_at  TEXT
);
CREATE INDEX IF NOT EXISTS idx_subject_state_popularity
    ON subject (state, popularity DESC);
"""


class _Retryable(Exception):
    """可重试的一次失败（网络抖动、限流、5xx）。"""


def popularity_of(raw: dict[str, Any]) -> int:
    """档案里的 `favorite` 是 `{wish, done, doing, on_hold, dropped}` 计数。

    求和作为「热度」代理：它衡量的是**有多少人把它收进了自己的收藏夹**，
    比评分覆盖更广（评分只覆盖 34%，收藏计数几乎每条都有）。
    """
    favorite = raw.get("favorite")
    if not isinstance(favorite, dict):
        return 0
    total = 0
    for value in favorite.values():
        if isinstance(value, bool):
            continue
        if isinstance(value, (int, float)):
            total += int(value)
    return total


def extract_cover_url(subject: dict[str, Any]) -> tuple[str | None, str]:
    """从 `/v0/subjects/{id}` 的响应里按优先级取图链。

    返回 `(url, reason)`：`url` 为 None 时 `reason` 说明为什么没有
    （`NOT_FOUND` / `NO_IMAGES`），便于统计「条目真没图」还是「接口没给」。
    """
    images = subject.get("images")
    if not isinstance(images, dict):
        return None, REASON_NO_IMAGES
    for size in COVER_SIZE_PREFERENCE:
        value = images.get(size)
        if isinstance(value, str) and value.strip():
            return value.strip(), REASON_OK
    return None, REASON_NO_IMAGES


class BangumiSubjectClient:
    """只读的单条查询客户端（`GET {base}/v0/subjects/{id}`）。

    刻意不做批量 / 搜索：契约只需要「按 id 取图链」这一件事，能力越大越容易
    被用成爬站工具。限流由调用方按请求间隔保证，这里只负责重试与错误归一。
    """

    def __init__(
        self,
        base_url: str,
        token: str | None = None,
        client: httpx.Client | None = None,
        timeout: float = 20.0,
        max_attempts: int = 3,
        backoff_seconds: float = 2.0,
        user_agent: str = "otaku-data-platform-sync/0.1.0",
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.max_attempts = max_attempts
        self.backoff_seconds = backoff_seconds
        self._client = client or httpx.Client(
            timeout=timeout, headers={"User-Agent": user_agent}
        )
        self._owns_client = client is None

    def close(self) -> None:
        if self._owns_client:
            self._client.close()

    def __enter__(self) -> "BangumiSubjectClient":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    @property
    def subject_url(self) -> str:
        return f"{self.base_url}/v0/subjects"

    def _headers(self) -> dict[str, str]:
        headers = {"Accept": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        return headers

    def _get(self, subject_id: str) -> httpx.Response:
        try:
            resp = self._client.get(
                f"{self.subject_url}/{subject_id}", headers=self._headers()
            )
        except (httpx.TimeoutException, httpx.TransportError) as exc:
            raise _Retryable(f"网络错误：{exc!r}") from exc
        if resp.status_code in (429, 500, 502, 503, 504):
            raise _Retryable(f"服务端返回 {resp.status_code}")
        return resp

    def fetch_cover(self, subject_id: str) -> tuple[str | None, str]:
        """返回 `(图链, 原因)`。网络类失败会在重试耗尽后回报 `NETWORK_ERROR`。

        404 不重试：条目已从上游删除是确定事实，再问一次也一样。
        """
        retryer = Retrying(
            stop=stop_after_attempt(self.max_attempts),
            wait=wait_fixed(self.backoff_seconds),
            retry=retry_if_exception_type(_Retryable),
            reraise=True,
        )
        try:
            resp = retryer(self._get, subject_id)
        except _Retryable:
            return None, REASON_NETWORK
        if resp.status_code == 404:
            return None, REASON_NOT_FOUND
        if resp.status_code != 200:
            return None, REASON_NETWORK
        try:
            data = resp.json()
        except ValueError:
            return None, REASON_NETWORK
        if not isinstance(data, dict):
            return None, REASON_NETWORK
        return extract_cover_url(data)


class CoverIndex:
    """sqlite 进度索引。整表只有 id / 类型 / 标题 / 热度 / 状态 / 结果，磁盘占用很小。"""

    def __init__(self, path: str) -> None:
        self.path = path
        parent = os.path.dirname(os.path.abspath(path))
        if parent:
            os.makedirs(parent, exist_ok=True)
        self.conn = sqlite3.connect(path)
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA synchronous=NORMAL")
        self.conn.executescript(_SCHEMA)
        self.conn.commit()

    def close(self) -> None:
        self.conn.close()

    def __enter__(self) -> "CoverIndex":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def upsert(self, rows: Iterable[tuple[int, str, str, int]]) -> int:
        """插入索引行。已存在的 id 保持原状——**不让重建索引把进度冲掉**。"""
        before = self.conn.total_changes
        self.conn.executemany(
            "INSERT OR IGNORE INTO subject (id, work_type, title, popularity)"
            " VALUES (?, ?, ?, ?)",
            rows,
        )
        self.conn.commit()
        return self.conn.total_changes - before

    def counts(self) -> dict[str, int]:
        result = {state: 0 for state in VALID_STATES}
        for state, count in self.conn.execute(
            "SELECT state, COUNT(*) FROM subject GROUP BY state"
        ):
            result[str(state)] = int(count)
        result["total"] = int(
            self.conn.execute("SELECT COUNT(*) FROM subject").fetchone()[0]
        )
        return result

    def pending(
        self,
        limit: int | None = None,
        order: str = "popularity",
        include_error: bool = False,
    ) -> list[tuple[int, str, str]]:
        """待处理行 `(id, work_type, title)`。

        `order="popularity"` 按热度降序（默认）；`order="archive"` 按 id 升序。
        `include_error=True` 时把上次网络失败的行也纳入重试范围。
        """
        states = [STATE_PENDING, STATE_ERROR] if include_error else [STATE_PENDING]
        placeholders = ",".join("?" for _ in states)
        if order == "archive":
            order_sql = "id ASC"
        else:
            order_sql = "popularity DESC, id ASC"
        sql = (
            f"SELECT id, work_type, title FROM subject"
            f" WHERE state IN ({placeholders}) ORDER BY {order_sql}"
        )
        params: list[Any] = list(states)
        if limit is not None:
            sql += " LIMIT ?"
            params.append(int(limit))
        return [(int(r[0]), str(r[1]), str(r[2])) for r in self.conn.execute(sql, params)]

    def mark(self, subject_id: int, state: str, cover_url: str | None = None) -> None:
        if state not in VALID_STATES:
            raise ValueError(f"未知状态：{state}")
        self.conn.execute(
            "UPDATE subject SET state = ?, cover_url = COALESCE(?, cover_url),"
            " updated_at = ? WHERE id = ?",
            (state, cover_url, utc_now(), int(subject_id)),
        )

    def mark_many(self, marks: Sequence[tuple[int, str, str | None]]) -> None:
        if not marks:
            return
        now = utc_now()
        self.conn.executemany(
            "UPDATE subject SET state = ?, cover_url = COALESCE(?, cover_url),"
            " updated_at = ? WHERE id = ?",
            [(state, url, now, int(sid)) for sid, state, url in marks],
        )
        self.conn.commit()


def build_index(
    index: CoverIndex,
    archive_path: str,
    work_types: Sequence[str] | None = None,
    limit: int | None = None,
) -> dict[str, int]:
    """从档案建索引。只留契约四类里、标题可用的条目。

    这一步是纯本地扫描（不联网），55.6 万条大约几分钟；重跑只会补齐新 id，
    已有行的状态（含已完成标记）不受影响。
    """
    wanted = tuple(work_types or ())
    stats = {
        "scanned": 0,
        "indexed": 0,
        "excluded": 0,
        "skipped_no_title": 0,
        "skipped_long_title": 0,
    }
    buffer: list[tuple[int, str, str, int]] = []
    for raw in iter_subjects(archive_path):
        stats["scanned"] += 1
        work_type = map_work_type(raw)
        if work_type is None or (wanted and work_type not in wanted):
            stats["excluded"] += 1
            continue
        title = pick_title(raw)
        if not title:
            stats["skipped_no_title"] += 1
            continue
        if len(title) > MAX_TITLE_LENGTH:
            stats["skipped_long_title"] += 1
            continue
        subject_id = raw.get("id")
        if subject_id is None:
            stats["skipped_no_title"] += 1
            continue
        buffer.append((int(subject_id), work_type, title, popularity_of(raw)))
        stats["indexed"] += 1
        if len(buffer) >= 2000:
            index.upsert(buffer)
            buffer.clear()
        if limit is not None and stats["indexed"] >= limit:
            break
    if buffer:
        index.upsert(buffer)
    return stats


class _RateLimiter:
    """按最小间隔发令牌的限速器，线程安全。

    关键点是**在锁外等待**：先在锁内把「下一个可用时刻」预定出去，再到锁外 sleep，
    这样多个工作线程可以同时等各自的时间片，互不阻塞。若在锁内 sleep，并发就退化成串行。
    """

    def __init__(self, interval_seconds: float, sleep=time.sleep) -> None:
        self.interval = max(0.0, float(interval_seconds))
        self._sleep = sleep
        self._lock = threading.Lock()
        self._next = time.monotonic()

    def wait(self) -> None:
        if self.interval <= 0:
            return
        with self._lock:
            slot = max(time.monotonic(), self._next)
            self._next = slot + self.interval
        delay = slot - time.monotonic()
        if delay > 0:
            self._sleep(delay)


@dataclass
class CoverBackfillReport:
    """一次回填运行的结果。字段口径与 pipeline 的报告保持一致（可直接落 json）。"""

    started_at: str
    source: str = SOURCE_BANGUMI
    dry_run: bool = True
    total_indexed: int = 0
    pending_at_start: int = 0
    processed: int = 0
    filled: int = 0
    missing: int = 0
    not_found: int = 0
    errors: int = 0
    delivered_items: int = 0
    batches: list[dict[str, Any]] = field(default_factory=list)
    samples: list[dict[str, Any]] = field(default_factory=list)
    index_stats: dict[str, int] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "started_at": self.started_at,
            "source": self.source,
            "dry_run": self.dry_run,
            "total_indexed": self.total_indexed,
            "pending_at_start": self.pending_at_start,
            "processed": self.processed,
            "filled": self.filled,
            "missing": self.missing,
            "not_found": self.not_found,
            "errors": self.errors,
            "delivered_items": self.delivered_items,
            "index_stats": self.index_stats,
            "batches": self.batches,
            "samples": self.samples,
        }


def _write_report(path: str, report: CoverBackfillReport) -> str:
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(report.to_dict(), handle, ensure_ascii=False, indent=2)
    return path


def _batch_id(stamp: str, seq: int) -> str:
    return f"bangumi-cover-{stamp}-{seq:04d}"


def run_backfill(
    config: SyncConfig,
    *,
    apply: bool = False,
    index_path: str | None = None,
    limit: int | None = None,
    order: str = "popularity",
    interval_seconds: float = 1.0,
    workers: int = 4,
    retry_failed: bool = False,
    report_dir: str | None = None,
    cover_client: BangumiSubjectClient | None = None,
    importer: JavaImporter | None = None,
    sleep=time.sleep,
) -> CoverBackfillReport:
    """跑一轮封面回填。

    `apply=False`（默认）只查不写：照样打上游接口、照样统计，但不提交、
    不改索引状态，用来先看清这批能补上多少张图。

    `interval_seconds` 是**总请求速率**的上限（间隔越短越快），`workers` 只是并发窗口：
    实测单次请求 1.1–3.8 秒，纯串行跑 55.6 万条要 18 天；开并发把延迟藏起来、速率仍由
    限流器卡住，才是「既快又不猛打上游」的做法。索引写入始终在主线程，不跨线程碰 sqlite。
    """
    started = utc_now()
    out_dir = report_dir or config.output_dir
    os.makedirs(out_dir, exist_ok=True)
    path = index_path or os.path.join(out_dir, "cover-index.sqlite")

    report = CoverBackfillReport(started_at=started, dry_run=not apply)
    index = CoverIndex(path)
    try:
        if index.counts()["total"] == 0:
            if not config.archive_path:
                raise ValueError(
                    "封面索引为空，需要 --archive <dump.zip> 才能建索引"
                )
            report.index_stats = build_index(
                index, config.archive_path, config.work_types
            )
        counts = index.counts()
        report.total_indexed = counts["total"]
        rows = index.pending(limit=limit, order=order, include_error=retry_failed)
        report.pending_at_start = counts[STATE_PENDING] + (
            counts[STATE_ERROR] if retry_failed else 0
        )

        client = cover_client or BangumiSubjectClient(
            config.bangumi_api_base_url,
            token=config.bangumi_token,
            timeout=config.timeout_seconds,
            max_attempts=config.max_attempts,
            backoff_seconds=config.backoff_seconds,
            user_agent=config.user_agent,
        )
        owns_client = cover_client is None
        owns_importer = False
        if importer is None:
            if apply:
                importer = JavaImporter(
                    config.java_base_url,
                    token=config.internal_token,
                    timeout=config.timeout_seconds,
                    max_attempts=config.max_attempts,
                    backoff_seconds=config.backoff_seconds,
                )
                owns_importer = True
            else:
                importer = None

        stamp = started.replace("-", "").replace(":", "").replace("+", "")
        stamp = stamp.split("T")[0] + "T" + stamp.split("T")[1][:6]
        seq = 0
        buffer: list[tuple[int, WorkItem, str]] = []

        def flush() -> None:
            nonlocal seq, buffer
            if not buffer:
                return
            pending, buffer = buffer, []
            if importer is None:
                for subject_id, item, url in pending:
                    report.delivered_items += 1
                    report.filled += 1
                    report.samples.append({"id": subject_id, "cover_url": url})
                return
            seq += 1
            batch_id = _batch_id(stamp, seq)
            entry: dict[str, Any] = {"batch_id": batch_id, "size": len(pending)}
            try:
                result = importer.submit_batch(
                    batch_id,
                    [item for _, item, _ in pending],
                    started,
                    source=SOURCE_BANGUMI,
                )
                entry["counts"] = dict(result.counts)
                entry["delivered"] = True
                rejected = int(result.counts.get("rejected", 0))
                if rejected:
                    # 被拒的条目多半是数据本身不合规（标题/地址异常）。标 error 而不是
                    # filled，避免索引谎报「这行有封面了」；重跑时会再试一次并由人工看报告。
                    entry["rejected"] = rejected
                    report.errors += rejected
                    index.mark_many([(sid, STATE_ERROR, None) for sid, _, _ in pending])
                else:
                    report.delivered_items += len(pending)
                    report.filled += len(pending)
                    index.mark_many(
                        [(sid, STATE_FILLED, url) for sid, _, url in pending]
                    )
            except Exception as exc:  # 网络/服务端错误：标 error 供下次 --cover-retry-failed
                entry["delivered"] = False
                entry["error"] = repr(exc)
                report.errors += len(pending)
                index.mark_many([(sid, STATE_ERROR, None) for sid, _, _ in pending])
            report.batches.append(entry)
            # 这是按天计的作业，stdout 是唯一的实时观测面（报告只在结束时落盘）。
            # 每批打一行，配合 `journalctl -u otaku-covers` 就能判断卡没卡、速率对不对。
            print(
                f"[{utc_now()}] 进度 {report.processed}/{len(rows)}"
                f" 有图 {report.filled} 无图 {report.missing}"
                f" 已删 {report.not_found} 失败 {report.errors}",
                flush=True,
            )

        limiter = _RateLimiter(interval_seconds, sleep=sleep)
        batch_size = max(1, config.batch_size)

        def consume(row: tuple[int, str, str], url: str | None, reason: str) -> None:
            subject_id, work_type, title = row
            report.processed += 1
            if url is None:
                if reason == REASON_NOT_FOUND:
                    report.not_found += 1
                    state = STATE_MISSING
                elif reason == REASON_NO_IMAGES:
                    report.missing += 1
                    state = STATE_MISSING
                else:
                    report.errors += 1
                    state = STATE_ERROR
                if apply:
                    index.mark(subject_id, state)
                return
            if apply:
                item = WorkItem(
                    source_record=SourceRecord(
                        source_id=str(subject_id),
                        source_url=SUBJECT_URL.format(subject_id=subject_id),
                        source=SOURCE_BANGUMI,
                    ),
                    work_type=work_type,
                    title=title,
                    cover_url=url,
                )
                buffer.append((subject_id, item, url))
                if len(buffer) >= batch_size:
                    flush()
            else:
                report.filled += 1
                if len(report.samples) < 20:
                    report.samples.append({"id": subject_id, "cover_url": url})

        def fetch_one(row: tuple[int, str, str]) -> tuple[str | None, str]:
            limiter.wait()
            try:
                return client.fetch_cover(str(row[0]))
            except Exception:  # 单条的意外异常不能拖死整轮，按失败记账等下轮
                return None, REASON_NETWORK

        try:
            # 单次请求实测 1.1–3.8 秒（镜像要回源到 bgm.tv），串行跑 55.6 万条是 18 天。
            # 真正该限的是**总请求速率**而不是并发数：并发只把延迟藏起来，节奏仍由
            # limiter 卡在 --cover-interval 上。窗口取 workers*2，同一时刻只有这么多个
            # 在飞，内存里不会堆起 55 万个 future。
            with ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
                iterator = iter(rows)
                inflight: dict[Any, tuple[int, str, str]] = {}
                for _ in range(max(1, workers) * 2):
                    row = next(iterator, None)
                    if row is None:
                        break
                    inflight[pool.submit(fetch_one, row)] = row
                while inflight:
                    done, _ = wait(list(inflight), return_when=FIRST_COMPLETED)
                    for future in done:
                        row = inflight.pop(future)
                        url, reason = future.result()
                        consume(row, url, reason)
                        nxt = next(iterator, None)
                        if nxt is not None:
                            inflight[pool.submit(fetch_one, nxt)] = nxt
            flush()
        finally:
            if apply:
                index.conn.commit()
            if owns_client:
                client.close()
            if owns_importer and importer is not None:
                importer.close()
    finally:
        index.close()

    _write_report(os.path.join(out_dir, f"cover-run-{stamp}.json"), report)
    return report


def summarize(report: CoverBackfillReport) -> str:
    lines = [
        f"封面回填{'（预演，未写入）' if report.dry_run else ''}"
        f"  索引 {report.total_indexed} 条，本次待处理 {report.pending_at_start} 条",
        f"  已查 {report.processed} 条：有图 {report.filled}、条目无图 {report.missing}"
        f"、条目已删 {report.not_found}、失败 {report.errors}",
    ]
    if not report.dry_run:
        lines.append(f"  写入 {report.delivered_items} 条，{len(report.batches)} 个批次")
        for batch in report.batches:
            if not batch.get("delivered"):
                lines.append(f"  批次 {batch['batch_id']} 未送达：{batch.get('error')}")
    return "\n".join(lines)