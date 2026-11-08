"""`scripts/backfill_series.py` 的回归测试。

## 为什么补这些

脚本只读首站 SQLite、只产 SQL，真正的危险在「聚合映射写错」：
- 首站 `series.id`（数字）→ 我们 `series_key`（字符串），类型别丢。
- `contents.bangumi_id` → 我们 `work.source_id`，按 series 聚合批量 UPDATE，
  同一 series 下的作品要进同一个 IN 列表，不能漏、不能串 series。
- 回滚只清「本批」写入（series 当前 0 行，DELETE 这批 key 是安全的）。

全部离线：不连 docker、不连 MySQL、不读真库——用内存 SQLite 造一张首站镜像。
只测纯逻辑（读映射 + SQL 生成），它们才是出过事的地方。
"""

import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from backfill_series import build_sql, read_first_site  # noqa: E402


def _make_first_site_conn() -> sqlite3.Connection:
    c = sqlite3.connect(":memory:")
    c.execute("CREATE TABLE series (id INTEGER PRIMARY KEY, name TEXT)")
    c.execute(
        "CREATE TABLE contents "
        "(bangumi_id INTEGER, series_id INTEGER)"
    )
    # 两个系列；系列 2 故意无名字（首站允许 name=NULL）
    c.executemany("INSERT INTO series (id, name) VALUES (?,?)",
                  [(1, "星际牛仔"), (2, None)])
    # 作品 10/11 归系列 1；作品 20 归系列 2；作品 30 无系列（不应出现）
    c.executemany("INSERT INTO contents (bangumi_id, series_id) VALUES (?,?)",
                  [(10, 1), (11, 1), (20, 2), (30, None)])
    c.commit()
    return c


def test_read_first_site_maps_types():
    c = _make_first_site_conn()
    series_rows, links = read_first_site(c)
    keys = {k for k, _ in series_rows}
    assert keys == {"1", "2"}, keys
    # name=NULL 也保留为 None
    assert dict(series_rows)["2"] is None
    # 只取 series_id 非空的链接，bangumi_id/series_id 都转字符串
    assert set(links) == {("10", "1"), ("11", "1"), ("20", "2")}
    assert ("30", "None") not in links


def test_build_sql_inserts_series_and_updates_works():
    c = _make_first_site_conn()
    series_rows, links = read_first_site(c)
    main_sql, rollback_sql, stats = build_sql(series_rows, links)

    # 主 SQL 含事务包裹
    assert "START TRANSACTION;" in main_sql and "COMMIT;" in main_sql
    # series 写入：两个 series 都进 INSERT，且 name=NULL 用 NULL 不是空串
    assert "INSERT IGNORE INTO series" in main_sql
    assert "'1', '星际牛仔'" in main_sql
    assert "'2', NULL" in main_sql
    # work.series_key 聚合：系列 1 的 10/11 在同一批 IN；系列 2 单独一批
    assert "source_id IN ('10', '11')" in main_sql
    assert "source_id IN ('20')" in main_sql
    # 只改空值
    assert "series_key IS NULL OR series_key=''" in main_sql
    # 统计
    assert stats["series_rows"] == 2
    assert stats["linked_contents"] == 3
    assert stats["works_touched_est"] == 3
    assert stats["distinct_series_in_links"] == 2


def test_rollback_only_clears_this_batch():
    c = _make_first_site_conn()
    series_rows, links = read_first_site(c)
    main_sql, rollback_sql, _ = build_sql(series_rows, links)

    assert "START TRANSACTION;" in rollback_sql and "COMMIT;" in rollback_sql
    # 回滚 DELETE 这批 series_key
    assert "DELETE FROM series WHERE series_key IN ('1', '2')" in rollback_sql
    # 回滚清空这批 work.source_id 对应的 series_key
    assert "source_id IN ('10', '11', '20')" in rollback_sql
    # 主 SQL 与回滚 SQL 不互相包含整段（结构不同）
    assert main_sql != rollback_sql


def test_large_in_batch_is_chunked():
    # 600 个作品归同一系列，应被拆成两批 IN（每批 500）
    series_rows = [("1", "X")]
    links = [(str(i), "1") for i in range(600)]
    main_sql, _, stats = build_sql(series_rows, links)
    assert stats["works_touched_est"] == 600
    # 两批 UPDATE
    assert main_sql.count("UPDATE work SET series_key='1'") == 2
