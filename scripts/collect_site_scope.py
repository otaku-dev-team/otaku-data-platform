#!/usr/bin/env python3
"""采一次「首站收录范围」：哪些 bangumi subject id 是首站收了的。

用途：后端要按「首站有没有收录」决定 app 里显示什么（存全量、显示子集）。
判定口径不自己写规则，直接问首站——它的每条作品都带 `bangumi_id`
（首站 `contents.bangumi_id` 还建了唯一索引，`api.py` 的列表/详情都会带上）。

输出的是清单，不是判定逻辑。首站改收录范围，重跑一次即可，我们不用改代码。

只读 GET。首站限流是「并发 ≤ 2、1–2 req/s、每天 ≤ 5 万」，这里串行 + 默认 0.8s 间隔，
一次全量大约 35 个请求、30 秒。**这是一次性的，别放进定时任务。**

用法：
    python scripts/collect_site_scope.py                     # 拉全量，摘要打到 stdout
    python scripts/collect_site_scope.py --out 某个.json      # 指定输出
    python scripts/collect_site_scope.py --sql                # 顺带输出 INSERT 语句
    python scripts/collect_site_scope.py --types anime        # 只拉一个类型（调试用）
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_BASE_URL = "http://154.8.194.198:8000"
DEFAULT_TYPES = ("anime", "comic", "game", "novel")
PAGE_SIZE = 200  # 接口硬上限是 500，但站主要求不超过 200，按 200 走
USER_AGENT = "otaku-data-platform-sync/0.1.0 (site-scope)"


def _get(url: str, timeout: float) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def fetch_type(base_url: str, work_type: str, interval: float, timeout: float) -> list[dict]:
    """翻完一个类型的全部分页。以 items 为空或到达 total_pages 结束。"""
    rows: list[dict] = []
    page = 1
    total_pages = None
    while True:
        query = urllib.parse.urlencode({"type": work_type, "page": page, "page_size": PAGE_SIZE})
        payload = _get(f"{base_url}/api/contents?{query}", timeout)
        items = payload.get("items") or []
        total_pages = payload.get("total_pages") or total_pages
        if not items:
            break
        for item in items:
            rows.append(
                {
                    "content_id": item.get("id"),
                    "type": item.get("type") or work_type,
                    "bangumi_id": item.get("bangumi_id"),
                    "title": item.get("title"),
                }
            )
        print(
            f"  {work_type} 第 {page}/{total_pages} 页，累计 {len(rows)}",
            file=sys.stderr,
        )
        if total_pages is not None and page >= int(total_pages):
            break
        page += 1
        time.sleep(interval)
    return rows


def emit_sql(rows: list[dict]) -> None:
    """把清单打成 INSERT 语句，供后端落一张 site_scope 表或回填标记。

    只输出有 bangumi_id 的行——没有的那部分本来就是首站独有，不影响判定。
    """
    ids = sorted({int(r["bangumi_id"]) for r in rows if r.get("bangumi_id") is not None})
    print("-- 首站收录的 bangumi subject id 清单，由 scripts/collect_site_scope.py 生成")
    print("-- 用法：先建表，再批量插入，最后按集合回填 work.site_listed")
    print("CREATE TABLE IF NOT EXISTS site_scope (")
    print("    subject_id BIGINT UNSIGNED NOT NULL COMMENT '首站 contents.bangumi_id',")
    print("    collected_at DATETIME(3) NOT NULL,")
    print("    PRIMARY KEY (subject_id)")
    print(") ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COMMENT '首站收录范围快照';")
    for start in range(0, len(ids), 500):
        chunk = ids[start : start + 500]
        values = ",".join(f"({i},NOW(3))" for i in chunk)
        print(f"INSERT IGNORE INTO site_scope (subject_id, collected_at) VALUES {values};")


def main() -> int:
    parser = argparse.ArgumentParser(description="采集首站收录范围（bangumi subject id）")
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--types", nargs="+", default=list(DEFAULT_TYPES))
    parser.add_argument("--interval", type=float, default=0.8, help="请求间隔秒，默认 0.8")
    parser.add_argument("--timeout", type=float, default=20.0)
    parser.add_argument("--out", default=None, help="输出 JSON 路径，默认 sync-python/runs/")
    parser.add_argument("--sql", action="store_true", help="把 INSERT 语句输出到 stdout")
    parser.add_argument(
        "--from-json",
        default=None,
        help="复用已有清单直接生成 SQL，不再发请求（改格式或补输出时用）",
    )
    args = parser.parse_args()

    base_url = args.base_url.rstrip("/")
    rows: list[dict] = []
    per_type: dict[str, int] = {}

    if args.from_json:
        saved = json.loads(Path(args.from_json).read_text(encoding="utf-8"))
        rows = saved.get("items", [])
        per_type = saved.get("per_type", {})
        if args.sql:
            emit_sql(rows)
        print(f"复用 {args.from_json}：{len(rows)} 条", file=sys.stderr)
        if not args.sql:
            print(json.dumps(saved.get("stats", {}), ensure_ascii=False))
        return 0

    try:
        for work_type in args.types:
            got = fetch_type(base_url, work_type, args.interval, args.timeout)
            per_type[work_type] = len(got)
            rows.extend(got)
            time.sleep(args.interval)
    except urllib.error.HTTPError as exc:
        print(f"HTTP {exc.code}：{exc.url}", file=sys.stderr)
        return 2
    except (urllib.error.URLError, TimeoutError) as exc:
        print(f"连不上：{exc}", file=sys.stderr)
        return 2

    with_bgm = [r for r in rows if r.get("bangumi_id") is not None]
    unique_ids = {int(r["bangumi_id"]) for r in with_bgm}

    out_path = Path(args.out) if args.out else (
        Path(__file__).resolve().parent.parent
        / "sync-python"
        / "runs"
        / f"site-scope-{datetime.now(timezone.utc):%Y%m%d-%H%M%S}.json"
    )
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        json.dumps(
            {
                "fetched_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "base_url": base_url,
                "page_size": PAGE_SIZE,
                "per_type": per_type,
                "stats": {
                    "rows": len(rows),
                    "with_bangumi_id": len(with_bgm),
                    "unique_subject_ids": len(unique_ids),
                },
                "items": rows,
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    print(f"总计 {len(rows)} 条，带 bangumi_id {len(with_bgm)} 条，唯一 subject id {len(unique_ids)} 个")
    print("按类型：" + "，".join(f"{k} {v}" for k, v in per_type.items()))
    print(f"清单写到 {out_path}")

    if args.sql:
        emit_sql(rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
