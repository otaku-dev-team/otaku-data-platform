#!/usr/bin/env python3
"""回填系列归属：从首站 SQLite 读取 series 与 contents.series_id，生成落到我们 MySQL 的 SQL。

只做一件事：把我们 `work.series_key`（目前全空）和 `series` 表（目前 0 行）按首站口径补上。
- 首站 `series.id`  → 我们 `series.series_key`（来源站自身 id，与 V37 注释一致）
- 首站 `contents.series_id` + `contents.bangumi_id`
  → 我们 `work.series_key`（WHERE work.source='bangumi' AND work.source_id = bangumi_id）

设计原则（与 backfill_article_related_works.py 一致）：
- 只读首站 SQLite（mode=ro），不连我们的库，不写任何东西——本脚本只产出 .sql 文本。
- INSERT IGNORE 进 series（series_key 为主键，幂等）；UPDATE 只改 series_key 为空的行。
- 产出两份文件：主 SQL（单事务）+ 回滚 SQL（清空这批写入，series 当前 0 行，可直接 DELETE 这批 key）。

用法（在服务器上跑，因为要读 /opt/acgn-test-platform/local_dev.db）：
    python3 backfill_series.py \
        --site-db /opt/acgn-test-platform/local_dev.db \
        --out /root/series_backfill.sql \
        --rollback /root/series_rollback.sql
"""
from __future__ import annotations

import argparse
import sqlite3
import sys
from typing import Iterable


def read_first_site(site_db: str | sqlite3.Connection) -> tuple[list[tuple[str, str | None]], list[tuple[str, str]]]:
    """返回 (series_rows, content_series_links)。

    series_rows: [(series_key, name), ...]  series_key 是首站 series.id 的字符串
    content_series_links: [(bangumi_id_str, series_key), ...]  来自 contents.series_id 非空

    site_db 可以是首站 SQLite 文件路径，或已打开的连接（测试用）。
    """
    own_conn = isinstance(site_db, sqlite3.Connection)
    c = site_db if own_conn else sqlite3.connect(f"file:{site_db}?mode=ro", uri=True)
    c.row_factory = sqlite3.Row
    try:
        # series 表：id 为主键，name 可能为 NULL（V37 注释：没名字就不拿 key 冒充）
        series_rows = [
            (str(r["id"]), r["name"])
            for r in c.execute("SELECT id, name FROM series")
        ]
        # contents：bangumi_id 即我们 work.source_id；series_id 指向 series.id
        links = [
            (str(r["bangumi_id"]), str(r["series_id"]))
            for r in c.execute(
                "SELECT bangumi_id, series_id FROM contents "
                "WHERE series_id IS NOT NULL AND bangumi_id IS NOT NULL"
            )
        ]
        return series_rows, links
    finally:
        if not own_conn:
            c.close()


def build_sql(series_rows: Iterable[tuple[str, str | None]],
              links: Iterable[tuple[str, str]]) -> tuple[str, str, dict]:
    """生成 (主 SQL, 回滚 SQL, 统计)。

    主 SQL：
      START TRANSACTION;
      INSERT IGNORE INTO series (series_key, name, created_at, updated_at) VALUES ...;
      UPDATE work SET series_key=? WHERE source='bangumi' AND source_id=? AND (series_key IS NULL OR series_key='');
      COMMIT;
    回滚 SQL：
      START TRANSACTION;
      UPDATE work SET series_key=NULL WHERE source='bangumi' AND source_id IN (...);  -- 仅这批
      DELETE FROM series WHERE series_key IN (...);  -- 仅这批（当前 series 0 行，安全）
      COMMIT;
    """
    series_rows = list(series_rows)
    links = list(links)

    out: list[str] = ["START TRANSACTION;", ""]

    # 1) series 表
    if series_rows:
        out.append("-- 1) 写入 series（幂等：series_key 主键，INSERT IGNORE）")
        out.append("INSERT IGNORE INTO series (series_key, name, created_at, updated_at) VALUES")
        val_lines = []
        for key, name in series_rows:
            nm = "NULL" if name is None else f"'{name.replace(chr(39), chr(39) * 2)}'"
            val_lines.append(f"  ('{key}', {nm}, NOW(3), NOW(3))")
        out.append(",\n".join(val_lines) + ";")
        out.append("")

    # 2) work.series_key —— 按 series_key 聚合，多行 IN 批量 UPDATE
    by_series: dict[str, list[str]] = {}
    for bangumi_id, series_key in links:
        by_series.setdefault(series_key, []).append(bangumi_id)

    out.append("-- 2) 回填 work.series_key（只改空值，按 series 聚合批量 UPDATE）")
    n_works = 0
    for series_key, ids in by_series.items():
        # 分批，避免单条 IN 过长（每批 500）
        for i in range(0, len(ids), 500):
            batch = ids[i:i + 500]
            id_list = ", ".join(f"'{x}'" for x in batch)
            out.append(
                f"UPDATE work SET series_key='{series_key}' "
                f"WHERE source='bangumi' AND source_id IN ({id_list}) "
                f"AND (series_key IS NULL OR series_key='');"
            )
            n_works += len(batch)
    out.append("")
    out.append("COMMIT;")
    main_sql = "\n".join(out)

    # 回滚：仅本批写入
    rollback_lines = ["START TRANSACTION;", ""]
    all_ids = [bid for _, bids in by_series.items() for bid in bids]
    if all_ids:
        id_list = ", ".join(f"'{x}'" for x in all_ids)
        rollback_lines.append(
            f"UPDATE work SET series_key=NULL "
            f"WHERE source='bangumi' AND source_id IN ({id_list});"
        )
    if series_rows:
        key_list = ", ".join(f"'{k}'" for k, _ in series_rows)
        rollback_lines.append(f"DELETE FROM series WHERE series_key IN ({key_list});")
    rollback_lines.append("")
    rollback_lines.append("COMMIT;")
    rollback_sql = "\n".join(rollback_lines)

    stats = {
        "series_rows": len(series_rows),
        "linked_contents": len(links),
        "works_touched_est": n_works,
        "distinct_series_in_links": len(by_series),
    }
    return main_sql, rollback_sql, stats


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="生成系列回填 SQL（只读首站，不写库）")
    ap.add_argument("--site-db", required=True, help="首站 SQLite 路径")
    ap.add_argument("--out", required=True, help="主 SQL 输出路径")
    ap.add_argument("--rollback", required=True, help="回滚 SQL 输出路径")
    args = ap.parse_args(argv)

    series_rows, links = read_first_site(args.site_db)
    main_sql, rollback_sql, stats = build_sql(series_rows, links)

    with open(args.out, "w", encoding="utf-8") as f:
        f.write(main_sql)
    with open(args.rollback, "w", encoding="utf-8") as f:
        f.write(rollback_sql)

    print("== 系列回填 SQL 已生成 ==")
    for k, v in stats.items():
        print(f"  {k}: {v}")
    print(f"  主 SQL:   {args.out}")
    print(f"  回滚 SQL: {args.rollback}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
