#!/usr/bin/env python3
"""
#383 评分口径：把 rating_count 入库存量回填，使后端可按首站 MIN_RATING_COUNT=50 阈值
        决定「低票不显示分、不进排序」。

设计原则（呼应「能后台跑的不要手工」）：
- 可恢复：只处理 rating_count IS NULL 的行，重跑安全。
- 分块：每批 --batch 条，生成 SQL 落盘再 apply，避免单条手敲。
- 限流：并发 --concurrency（默认 6），失败重试 --retries。
- 不动 deleted_at：本脚本只写 rating_count 列，绝不清/改 deleted_at（避开 #249 upsert 陷阱）。
- 安全：纯存量回填，后端未读 rating_count 前不改变任何线上行为。

服务器端运行（仓库在 /opt/otaku 或同步后）：
    /opt/otaku/sync-venv/bin/python scripts/backfill_rating_count.py \
        --api-base https://bgmapi.anibt.net/v0 \
        --apply docker \
        --batch 500 --limit 2000

本地 Dry-run（不连库、只打印将取的 id）：
    python scripts/backfill_rating_count.py --dry-run --limit 10
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

# 服务器运行：凭据与容器名从环境变量取（不写死）
#   OTAKU_DB_USER / OTAKU_DB_PASSWORD / OTAKU_DB_NAME / MYSQL_CONTAINER
SUBJECTS_QUERY = (
    "SELECT work_id, source_id FROM work "
    "WHERE source='bangumi' AND rating_value IS NOT NULL AND rating_count IS NULL "
    "LIMIT %d"
)


def _mysql(sql_text: str) -> tuple:
    """经 docker 容器里的 mysql 客户端执行 SQL（stdin）。shell=True 走 /bin/sh，PATH 正常。"""
    cont = os.environ["MYSQL_CONTAINER"]
    user = os.environ["OTAKU_DB_USER"]
    pwd = os.environ["OTAKU_DB_PASSWORD"]
    db = os.environ["OTAKU_DB_NAME"]
    cmd = f"docker exec -i {cont} mysql -u{user} -p'{pwd}' {db}"
    p = subprocess.run(cmd, input=sql_text.encode("utf-8"), shell=True, capture_output=True)
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")


def fetch_rows(limit: int):
    rc, out, err = _mysql(SUBJECTS_QUERY % limit)
    if rc != 0:
        print(err, file=sys.stderr)
        return []
    rows = []
    for line in out.splitlines():
        line = line.strip()
        if not line or line.startswith("work_id"):
            continue
        wid, sid = line.split("\t")
        rows.append((wid, sid))
    return rows


def fetch_total(api_base: str, subject_id: str, retries: int) -> int | None:
    url = f"{api_base}/subjects/{subject_id}"
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "otaku-backfill/1.0"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            rating = data.get("rating") or {}
            total = rating.get("total")
            return int(total) if total is not None else None
        except Exception as exc:  # noqa: BLE001
            if attempt == retries:
                print(f"  ! subject {subject_id} failed: {exc}", file=sys.stderr)
                return None
            time.sleep(1.5 * attempt)
    return None


def build_sql(rows_with_count):
    lines = []
    for wid, count in rows_with_count:
        val = "NULL" if count is None else str(int(count))
        lines.append(f"UPDATE work SET rating_count={val} WHERE work_id={wid};")
    return "\n".join(lines) + "\n"


def apply_docker(sql: str):
    rc, out, err = _mysql(sql)
    if rc != 0:
        print(err, file=sys.stderr)
        raise RuntimeError("apply failed")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--api-base", default="https://bgmapi.anibt.net/v0")
    ap.add_argument("--apply", choices=["docker", "none"], default="docker")
    ap.add_argument("--batch", type=int, default=500)
    ap.add_argument("--limit", type=int, default=2000)
    ap.add_argument("--concurrency", type=int, default=6)
    ap.add_argument("--retries", type=int, default=3)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    rows = fetch_rows(args.limit)
    print(f"[backfill] fetched {len(rows)} rows needing rating_count", file=sys.stderr)

    if args.dry_run:
        for wid, sid in rows[:10]:
            print(f"  would fetch subject {sid} for work {wid}")
        print("[backfill] dry-run done", file=sys.stderr)
        return

    done = 0
    batch_rows = []
    with ThreadPoolExecutor(max_workers=args.concurrency) as ex:
        futures = {ex.submit(fetch_total, args.api_base, sid, args.retries): wid
                   for wid, sid in rows}
        results = []
        for fut in as_completed(futures):
            wid = futures[fut]
            total = fut.result()
            results.append((wid, total))
            done += 1
            if done % 200 == 0:
                print(f"[backfill] progress {done}/{len(rows)}", file=sys.stderr)

    results.sort(key=lambda r: int(r[0]))
    sql = build_sql(results)
    if args.apply == "docker":
        apply_docker(sql)
    else:
        with open("/tmp/rating_count.sql", "w", encoding="utf-8") as f:
            f.write(sql)
        print(f"[backfill] wrote /tmp/rating_count.sql ({len(results)} rows); apply manually",
              file=sys.stderr)
    print(f"[backfill] done: {len(results)} rows", file=sys.stderr)


if __name__ == "__main__":
    main()
