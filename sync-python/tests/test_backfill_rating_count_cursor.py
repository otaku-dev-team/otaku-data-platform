"""回填脚本的游标行为（scripts/backfill_rating_count.py）。

为什么值得一个测试：这脚本 2026-11-03 在线上白白跑了很久——不是网络问题，
是取数没有 `ORDER BY id`，队首一整段镜像永久 404 的条目写不进去、永远留在队首，
每一轮都在重抓同一段死区，回填量停在 11,191 不再增长。

游标（`id > N ORDER BY id`）是这条链路的**推进机制**，删了不会报错，只会让回填悄悄停滞——
所以钉在这里：少了 `ORDER BY id` 或少解析了 id 列，测试就红。

脚本在 `scripts/`（不在 sync-python 包里），CI 只跑 `sync-python` 的 pytest，
所以这里按路径加载，而不是把它挪进包。
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "backfill_rating_count.py"


@pytest.fixture()
def script():
    spec = importlib.util.spec_from_file_location("backfill_rating_count", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_query_is_ordered_and_cursor_aware(script):
    """取数必须带游标与排序，否则会在死区上原地打转。"""
    captured = {}

    def fake_mysql(sql: str):
        captured["sql"] = sql
        return 0, "", ""

    script._mysql = fake_mysql
    script.fetch_rows(10, 5)

    sql = " ".join(captured["sql"].split())
    assert "id > 5" in sql
    assert "ORDER BY id" in sql
    assert "LIMIT 10" in sql


def test_returns_next_cursor_and_skips_header(script):
    """下一轮游标取本批最大 id；表头行不能被当成数据。"""

    def fake_mysql(sql: str):
        # 带表头、带 \r，模拟 docker exec 的输出
        return 0, "id\twork_id\tsource_id\r\n12\tW-1\t100\r\n13\tW-2\t101\r\n", ""

    script._mysql = fake_mysql
    rows, next_cursor = script.fetch_rows(10, 0)

    assert rows == [("W-1", "100"), ("W-2", "101")]
    assert next_cursor == 13


def test_keeps_cursor_when_nothing_left(script):
    """空结果时游标不倒退——否则下一轮会从更小的 id 重新扫。"""

    def fake_mysql(sql: str):
        return 0, "", ""

    script._mysql = fake_mysql
    rows, next_cursor = script.fetch_rows(10, 42)

    assert rows == []
    assert next_cursor == 42


def test_mysql_failure_raises_instead_of_empty(script):
    """mysql 抖动必须冒泡。返回 `[]` 会让外层把「查不到」当成「填完了」而永久停机（#394）。"""

    def fake_mysql(sql: str):
        return 1, "", "ERROR 2002: Can't connect"

    script._mysql = fake_mysql
    with pytest.raises(RuntimeError):
        script.fetch_rows(10, 0)


def test_count_pending_reads_last_line(script):
    """`count_pending` 取的是最后一行数字，不能把表头当成数字。"""

    def fake_mysql(sql: str):
        assert "COUNT(*)" in sql
        return 0, "COUNT(*)\r\n70123\r\n", ""

    script._mysql = fake_mysql
    assert script.count_pending() == 70123
