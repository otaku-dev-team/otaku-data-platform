"""`scripts/backfill_rating_count.py` 的回归测试。

## 为什么补这些

这个脚本是**长任务 + 线上数据 + 无界面**的组合，出问题时的表现是「跑了一夜，数没涨」——
没人看得见。已经踩过两次静默失败，两次都不是崩溃，而是「看起来跑完了」：

1. **队列不前进**（2026-11-03 实测）：取数没带 `ORDER BY id` / 游标，队首是一整段镜像
   永久 404 的条目，写不进去就永远留在队首 → 每轮重抓同一段死区，回填量停在 11,191。
2. **静默失败被当成跑完**（#394）：mysql 抖动时 `fetch_rows` 返回 `[]`，外层把「查不到」
   当成「填完了」直接停止续跑。

修法分别是 `--after-id` 游标与「失败冒泡 + `ALL_DONE` / `PASS_DONE` 两种空语义」。
本文件把这两条**钉成断言**：函数签名可以改，行为不能退回去。

## 怎么测

全部离线：`_mysql` 被 monkeypatch 成假实现，不连 docker、不连 MySQL、不发网络请求。
只测「解析 / 游标 / 失败语义 / 两种空 / SQL 生成」这些纯逻辑——它们才是出过事的地方。
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys

import pytest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "backfill_rating_count.py"


def _load():
    spec = importlib.util.spec_from_file_location("backfill_rating_count", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


@pytest.fixture()
def backfill(monkeypatch):
    module = _load()
    # 默认给一组无害的环境变量：万一某条用例漏了 mock 也只会读到这里，不会碰真库。
    for key in ("MYSQL_CONTAINER", "OTAKU_DB_USER", "OTAKU_DB_PASSWORD", "OTAKU_DB_NAME"):
        monkeypatch.setenv(key, "test")
    return module


def _fake_mysql(backfill, monkeypatch, responses):
    """按顺序返回 `_mysql` 的响应；用完后重复最后一个。"""
    calls = []
    queue = list(responses)

    def fake(sql):
        calls.append(sql)
        return queue.pop(0) if len(queue) > 1 else queue[0]

    monkeypatch.setattr(backfill, "_mysql", fake)
    return calls


# ----------------------------------------------------------------------
# fetch_rows：解析与游标
# ----------------------------------------------------------------------


def test_fetch_rows_parses_tsv_and_advances_cursor(backfill, monkeypatch):
    _fake_mysql(backfill, monkeypatch, [
        (0, "id\twork_id\tsource_id\n"
            "101\tW-a\tsubject/1\n"
            "205\tW-b\tsubject/2\n", ""),
    ])

    rows, max_id = backfill.fetch_rows(limit=10, after_id=0)

    assert rows == [("W-a", "subject/1"), ("W-b", "subject/2")]
    assert max_id == 205  # 游标必须停在最大 id 上，下一轮才能越过这段


def test_fetch_rows_keeps_given_cursor_when_no_rows(backfill, monkeypatch):
    """空结果时游标不能倒退成 0——否则下一轮又从死区开头重抓。"""
    _fake_mysql(backfill, monkeypatch, [(0, "id\twork_id\tsource_id\n", "")])

    rows, max_id = backfill.fetch_rows(limit=10, after_id=4200)

    assert rows == []
    assert max_id == 4200


def test_fetch_rows_raises_on_mysql_failure(backfill, monkeypatch):
    """#394：mysql 抖动必须冒泡。返回 [] 会让上层误判为「已填完」。"""
    _fake_mysql(backfill, monkeypatch, [(1, "", "Lost connection to MySQL server")])

    with pytest.raises(RuntimeError) as err:
        backfill.fetch_rows(limit=10, after_id=0)

    assert "Lost connection" in str(err.value)


def test_fetch_rows_skips_malformed_lines(backfill, monkeypatch, capsys):
    _fake_mysql(backfill, monkeypatch, [
        (0, "id\twork_id\tsource_id\n"
            "101\tW-a\n"          # 少一列
            "abc\tW-x\tsubject/x\n"  # id 非数值：行照样收，游标不前进
            "102\tW-b\tsubject/2\n", ""),
    ])

    rows, max_id = backfill.fetch_rows(limit=10, after_id=0)

    assert rows == [("W-x", "subject/x"), ("W-b", "subject/2")]
    assert max_id == 102
    assert "skip malformed row" in capsys.readouterr().err


# ----------------------------------------------------------------------
# count_pending：区分两种「空」
# ----------------------------------------------------------------------


def test_count_pending_reads_last_line(backfill, monkeypatch):
    _fake_mysql(backfill, monkeypatch, [(0, "COUNT(*)\n67\n", "")])
    assert backfill.count_pending() == 67


def test_count_pending_raises_when_mysql_fails(backfill, monkeypatch):
    _fake_mysql(backfill, monkeypatch, [(2, "", "boom")])
    with pytest.raises(RuntimeError):
        backfill.count_pending()


def test_count_pending_raises_on_empty_output(backfill, monkeypatch):
    """拿不到计数时不能猜 0——猜 0 就等于宣布「全填完了」。"""
    _fake_mysql(backfill, monkeypatch, [(0, "", "")])
    with pytest.raises(RuntimeError):
        backfill.count_pending()


# ----------------------------------------------------------------------
# build_sql / apply_docker
# ----------------------------------------------------------------------


def test_build_sql_writes_null_for_missing_count(backfill):
    sql = backfill.build_sql([("W-a", 12), ("W-b", None)])

    assert "UPDATE work SET rating_count=12 WHERE work_id='W-a';" in sql
    assert "UPDATE work SET rating_count=NULL WHERE work_id='W-b';" in sql


def test_apply_docker_falls_back_to_per_statement(backfill, monkeypatch, capsys):
    """整批失败要降级逐条，而不是整批 5000 行全丢、下轮重抓又失败。"""
    calls = _fake_mysql(backfill, monkeypatch, [
        (1, "", "server has gone away"),  # 整批失败
        (0, "", ""),                       # 第 1 条成功
        (1, "", "bad row"),                # 第 2 条失败
    ])

    backfill.apply_docker("UPDATE work SET rating_count=1 WHERE work_id='W-a';\n"
                          "UPDATE work SET rating_count=2 WHERE work_id='W-b';\n")

    assert len(calls) == 3  # 1 次整批 + 2 次逐条
    assert "per-statement apply done with 1 failed" in capsys.readouterr().err


# ----------------------------------------------------------------------
# main：两种空必须分开（PASS_DONE vs ALL_DONE）
# ----------------------------------------------------------------------


def _run_main(backfill, monkeypatch, *, rows, max_id, remaining):
    monkeypatch.setattr(sys, "argv", ["backfill", "--limit", "10"])
    monkeypatch.setattr(backfill, "fetch_rows", lambda limit, after_id: (rows, max_id))
    monkeypatch.setattr(backfill, "count_pending", lambda: remaining)
    backfill.main()


def test_main_reports_pass_done_when_cursor_hit_end_but_rows_remain(backfill, monkeypatch, capsys):
    """扫到末尾 ≠ 全填完：死区条目还挂着，得回头再扫。"""
    _run_main(backfill, monkeypatch, rows=[], max_id=99999, remaining=7)

    err = capsys.readouterr().err
    assert "PASS_DONE" in err
    assert "ALL_DONE" not in err
    assert "--after-id=0" in err


def test_main_reports_all_done_only_when_nothing_pending(backfill, monkeypatch, capsys):
    _run_main(backfill, monkeypatch, rows=[], max_id=99999, remaining=0)

    err = capsys.readouterr().err
    assert "ALL_DONE" in err
    assert "PASS_DONE" not in err


def test_main_exits_2_when_fetch_fails(backfill, monkeypatch, capsys):
    """外层脚本靠 exit 2 判断「该重试」；给 0 会被当成跑完了。"""
    monkeypatch.setattr(sys, "argv", ["backfill", "--limit", "10"])

    def boom(limit, after_id):
        raise RuntimeError("mysql down")

    monkeypatch.setattr(backfill, "fetch_rows", boom)

    with pytest.raises(SystemExit) as exit_info:
        backfill.main()

    assert exit_info.value.code == 2
    assert "FETCH_ERROR" in capsys.readouterr().err


def test_main_dry_run_prints_next_cursor_and_writes_nothing(backfill, monkeypatch, capsys):
    monkeypatch.setattr(sys, "argv", ["backfill", "--dry-run", "--limit", "10"])
    monkeypatch.setattr(backfill, "fetch_rows", lambda limit, after_id: ([("W-a", "subject/1")], 321))

    def fail(*_args, **_kwargs):
        raise AssertionError("dry-run 不应触碰 apply / count")

    monkeypatch.setattr(backfill, "apply_docker", fail)
    monkeypatch.setattr(backfill, "count_pending", fail)

    backfill.main()

    err = capsys.readouterr().err
    assert "next --after-id=321" in err
