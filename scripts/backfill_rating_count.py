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
        --batch 500 --limit 2000 --after-id 0
    跑完会打印 `next --after-id=N`，下一轮带上继续；扫到末尾会打印 `PASS_DONE`，
    此时带 `--after-id=0` 再扫一遍可重试跳过的死区；只有全库都填完才打印 `ALL_DONE`。

本地 Dry-run（不连库、只打印将取的 id）：
    python scripts/backfill_rating_count.py --dry-run --limit 10
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

# 服务器运行：凭据与容器名从环境变量取（不写死）
#   OTAKU_DB_USER / OTAKU_DB_PASSWORD / OTAKU_DB_NAME / MYSQL_CONTAINER
SUBJECTS_QUERY = (
    "SELECT id, work_id, source_id FROM work "
    "WHERE source='bangumi' AND rating_value IS NOT NULL AND rating_count IS NULL "
    "AND id > %d ORDER BY id LIMIT %d"
)

PENDING_COUNT_QUERY = (
    "SELECT COUNT(*) FROM work "
    "WHERE source='bangumi' AND rating_value IS NOT NULL AND rating_count IS NULL"
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


def fetch_rows(limit: int, after_id: int = 0):
    """按 id 递增取一批待回填的行，返回 (rows, max_id)。

    <p>**必须带游标**（2026-11-03 实测）：原来只取「前 N 条」且没有 `ORDER BY`，
    队首那段镜像永久 404 的条目写不进去、永远留在队首，于是每一轮都在重抓同一段死区，
    回填量停在 11,191 不再增长——看起来像"跑不动"，实际是队列不前进。
    实测：队首前 500 条全是 404，`ORDER BY id` 的 offset 500 之后立刻恢复 200（id=635 → 200）。

    <p>mysql 抖动仍然冒泡（#394），不要退回静默 `[]`：上层会把"查不到"当成"填完了"。
    """
    rc, out, err = _mysql(SUBJECTS_QUERY % (after_id, limit))
    if rc != 0:
        # 不再静默返回 []：mysql 抖动必须冒泡，否则上层会误判为"已无待处理行"而停止续跑
        raise RuntimeError(f"fetch_rows mysql failed (rc={rc}): {err[:500]}")
    rows = []
    max_id = after_id
    for line in out.splitlines():
        line = line.strip()
        if not line or line.startswith("id\t"):
            continue
        parts = line.split("\t")
        if len(parts) != 3:
            print(f"  ! skip malformed row: {line!r}", file=sys.stderr)
            continue
        row_id, wid, sid = parts
        rows.append((wid, sid))
        try:
            max_id = max(max_id, int(row_id))
        except ValueError:
            continue
    return rows, max_id


def count_pending() -> int:
    """还剩多少行没填。用来区分「真的跑完了」和「这一遍扫到末尾，但前面还有没填进去的」。"""
    rc, out, err = _mysql(PENDING_COUNT_QUERY)
    if rc != 0:
        raise RuntimeError(f"count_pending mysql failed (rc={rc}): {err[:500]}")
    text = out.strip().splitlines()
    if not text:
        raise RuntimeError("count_pending returned no rows")
    return int(text[-1].strip())


def fetch_total(api_base: str, subject_id: str, retries: int) -> int | None:
    url = f"{api_base}/subjects/{subject_id}"
    last = None
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "otaku-backfill/1.0"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            rating = data.get("rating") or {}
            total = rating.get("total")
            return int(total) if total is not None else None
        except urllib.error.HTTPError as he:
            if he.code == 404:
                return None  # 镜像确实没有该 subject，确定性结论，不重试
            last = he
        except json.JSONDecodeError as je:
            # 镜像偶发返回非 JSON（如 HTML 错误页），视为无数据，不重试
            last = je
        except Exception as exc:  # noqa: BLE001
            last = exc
        if attempt < retries:
            time.sleep(1.5 * attempt)
    print(f"  ! subject {subject_id} failed: {last}", file=sys.stderr)
    return None


def build_sql(rows_with_count):
    lines = []
    for wid, count in rows_with_count:
        val = "NULL" if count is None else str(int(count))
        lines.append(f"UPDATE work SET rating_count={val} WHERE work_id='{wid}';")
    return "\n".join(lines) + "\n"


def apply_docker(sql: str):
    rc, out, err = _mysql(sql)
    if rc == 0:
        return out
    # 整批 apply 失败（如管道偶发抖动），降级为逐条 apply：绝大多数能落盘，
    # 仅真正坏的单条被跳过，避免整批 5000 行不落盘导致下轮重抓又失败死循环
    print(f"  ! batch apply failed (rc={rc}): {err[:300]}, retrying per-statement", file=sys.stderr)
    failed = 0
    for stmt in sql.strip().split("\n"):
        stmt = stmt.strip()
        if not stmt:
            continue
        r2, _, e2 = _mysql(stmt)
        if r2 != 0:
            failed += 1
            if failed <= 5:
                print(f"  ! stmt failed: {stmt[:120]} -> {e2[:200]}", file=sys.stderr)
    if failed:
        print(f"  ! per-statement apply done with {failed} failed statements "
              f"(kept as NULL, will retry next run)", file=sys.stderr)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--api-base", default="https://bgmapi.anibt.net/v0")
    ap.add_argument("--apply", choices=["docker", "none"], default="docker")
    ap.add_argument("--batch", type=int, default=500)
    ap.add_argument("--limit", type=int, default=2000)
    ap.add_argument("--concurrency", type=int, default=6)
    ap.add_argument("--retries", type=int, default=3)
    ap.add_argument("--after-id", type=int, default=0,
                    help="游标：只处理 id 大于它的行。跑完会打印下一次该用的值")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    try:
        rows, max_id = fetch_rows(args.limit, args.after_id)
    except RuntimeError as e:
        # mysql 抖动：冒泡到非 0 退出，让外层循环 sleep 后重试，而非误判为"已完成"
        print(f"[backfill] FETCH_ERROR: {e}", file=sys.stderr)
        sys.exit(2)
    print(f"[backfill] fetched {len(rows)} rows needing rating_count"
          f" (after_id={args.after_id})", file=sys.stderr)

    if args.dry_run:
        for wid, sid in rows[:10]:
            print(f"  would fetch subject {sid} for work {wid}")
        print(f"[backfill] dry-run done; next --after-id={max_id}", file=sys.stderr)
        return

    if not rows:
        # 两种"空"必须分开：游标扫到末尾 ≠ 全库填完。
        # 前者说明这一遍跳过的死区条目（镜像永久 404）还挂着，要回头再扫一遍；
        # 只有全库真的没有 NULL 了才是 ALL_DONE，外层循环见此才停。
        try:
            remaining = count_pending()
        except RuntimeError as e:
            print(f"[backfill] FETCH_ERROR: {e}", file=sys.stderr)
            sys.exit(2)
        if remaining == 0:
            print("[backfill] ALL_DONE: no rows needing rating_count", file=sys.stderr)
        else:
            print(f"[backfill] PASS_DONE: 已扫到末尾，仍有 {remaining} 行未填"
                  f"（多为镜像 404 的死区）；再跑请带 --after-id=0", file=sys.stderr)
        return

    done = 0
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

    results.sort(key=lambda r: r[0])
    sql = build_sql(results)
    if args.apply == "docker":
        apply_docker(sql)
    else:
        with open("/tmp/rating_count.sql", "w", encoding="utf-8") as f:
            f.write(sql)
        print(f"[backfill] wrote /tmp/rating_count.sql ({len(results)} rows); apply manually",
              file=sys.stderr)
    print(f"[backfill] done: {len(results)} rows; next --after-id={max_id}", file=sys.stderr)


if __name__ == "__main__":
    main()
