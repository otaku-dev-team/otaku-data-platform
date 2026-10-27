"""变更感知测试：新增 / 改动 / 删除 三个集合算得对不对。

这些用例守的是一条具体承诺：**不靠源侧 `updated_at` 也能知道谁变了**。
每条用例都对应一种真实的变更形态（改标题、加标签、删作品、只动同步时间戳），
不是为了凑覆盖率。

最要紧的两条：
- 同一份数据跑两次必须「无变更」——否则每天都会全量重投，等于没做；
- 删掉的作品必须出现——后端是 upsert，没有删除信号就会永远留着。
"""

from __future__ import annotations

import sqlite3

import pytest

from sync.dataset import build_manifest, diff_manifests, is_compatible, load_manifest
from sync.dataset import manifest as manifest_mod
from sync.dataset.manifest import Manifest, save_manifest
from sync.dataset.schema import DDL


def _make_dataset(path, *, works=(), tags=(), credits=(), schedules=()):
    """直接按数据集 DDL 造一份数据集，不走导出器（测的是指纹，不是导出）。"""
    conn = sqlite3.connect(str(path))
    try:
        conn.executescript(DDL)
        conn.executemany(
            "INSERT INTO works(source_id, work_type, title, summary) VALUES (?,?,?,?)",
            works,
        )
        conn.executemany(
            "INSERT INTO work_tags(source_id, name) VALUES (?,?)", tags
        )
        conn.executemany(
            "INSERT INTO work_credits(source_id, role, name, sort_order) VALUES (?,?,?,?)",
            credits,
        )
        conn.executemany(
            "INSERT INTO schedules(source_id, title_main, weekday, source_updated_at)"
            " VALUES (?,?,?,?)",
            schedules,
        )
        conn.commit()
    finally:
        conn.close()
    return path


@pytest.fixture()
def dataset_factory(tmp_path):
    def _factory(name, **kwargs):
        return _make_dataset(tmp_path / name, **kwargs)

    return _factory


def test_first_run_counts_everything_as_added(dataset_factory):
    path = dataset_factory("a.db", works=[("w1", "anime", "甲", None)])
    current = build_manifest(path)

    diff = diff_manifests(Manifest(), current)

    assert diff.kinds["works"].added == ("w1",)
    assert diff.changed == 0 and diff.deleted == 0
    assert current.total == 1


def test_identical_dataset_reports_no_change(dataset_factory):
    kwargs = dict(
        works=[("w1", "anime", "甲", "简介"), ("w2", "comic", "乙", None)],
        tags=[("w1", "奇幻"), ("w1", "日常")],
        credits=[("w1", "原作", "某人", 1)],
    )
    first = build_manifest(dataset_factory("a.db", **kwargs))
    second = build_manifest(dataset_factory("b.db", **kwargs))

    assert diff_manifests(first, second).is_empty


def test_title_edit_marks_only_that_work(dataset_factory):
    first = build_manifest(
        dataset_factory(
            "a.db",
            works=[("w1", "anime", "旧标题", None), ("w2", "anime", "乙", None)],
        )
    )
    second = build_manifest(
        dataset_factory(
            "b.db",
            works=[("w1", "anime", "新标题", None), ("w2", "anime", "乙", None)],
        )
    )

    diff = diff_manifests(first, second)

    assert diff.kinds["works"].changed == ("w1",)
    assert diff.kinds["works"].added == ()
    assert diff.kinds["works"].deleted == ()


def test_deleted_work_is_detected_with_its_children(dataset_factory):
    first = build_manifest(
        dataset_factory(
            "a.db",
            works=[("w1", "anime", "甲", None), ("w2", "anime", "乙", None)],
            tags=[("w2", "日常")],
        )
    )
    second = build_manifest(
        dataset_factory(
            "b.db",
            works=[("w1", "anime", "甲", None)],
            tags=[],
        )
    )

    diff = diff_manifests(first, second)

    assert diff.kinds["works"].deleted == ("w2",)
    assert diff.deleted == 1


def test_child_row_change_marks_parent_work(dataset_factory):
    first = build_manifest(
        dataset_factory("a.db", works=[("w1", "anime", "甲", None)], tags=[("w1", "奇幻")])
    )
    second = build_manifest(
        dataset_factory(
            "b.db",
            works=[("w1", "anime", "甲", None)],
            tags=[("w1", "奇幻"), ("w1", "日常")],
        )
    )

    diff = diff_manifests(first, second)

    assert diff.kinds["works"].changed == ("w1",)


def test_child_row_order_does_not_fake_a_change(dataset_factory):
    """子表没有主键，SQLite 返回顺序不保证——顺序不同不能算变更。"""
    rows = [("w1", "奇幻"), ("w1", "日常"), ("w1", "战斗")]
    first = build_manifest(
        dataset_factory("a.db", works=[("w1", "anime", "甲", None)], tags=rows)
    )
    second = build_manifest(
        dataset_factory(
            "b.db", works=[("w1", "anime", "甲", None)], tags=list(reversed(rows))
        )
    )

    assert diff_manifests(first, second).is_empty


def test_volatile_sync_timestamp_is_ignored(dataset_factory):
    """档期的 source_updated_at 源侧每同步一次就变，不能算内容变更。"""
    first = build_manifest(
        dataset_factory(
            "a.db", schedules=[("s1", "甲", 3, "2026-10-27T00:00:00Z")]
        )
    )
    second = build_manifest(
        dataset_factory(
            "b.db", schedules=[("s1", "甲", 3, "2026-10-28T09:30:00Z")]
        )
    )
    assert diff_manifests(first, second).is_empty

    third = build_manifest(
        dataset_factory(
            "c.db", schedules=[("s1", "甲", 5, "2026-10-28T09:30:00Z")]
        )
    )
    assert diff_manifests(second, third).kinds["schedules"].changed == ("s1",)


def test_orphan_child_rows_are_counted(dataset_factory):
    path = dataset_factory("a.db", works=[("w1", "anime", "甲", None)], tags=[("w9", "野")])

    current = build_manifest(path)

    assert current.orphans == {"work_tags": 1}


def test_manifest_roundtrip_and_version(dataset_factory, tmp_path):
    path = dataset_factory("a.db", works=[("w1", "anime", "甲", None)])
    current = build_manifest(path)
    store = tmp_path / "state" / "dataset.manifest.db"

    save_manifest(
        store, current, source_id="otaku", dataset_path=str(path), generated_at="now"
    )

    reloaded = load_manifest(store)
    # 没有任何实体的类型不落盘（表里没行可存），所以只比有内容的部分；
    # 差集计算用的是「两份指纹的键并集」，缺键等价于空集合，不受影响。
    assert reloaded.entries == {k: v for k, v in current.entries.items() if v}
    assert is_compatible(store)

    # 版本不一致时不能硬比，否则格式升级会被误报成几十万条变更
    manifest_mod.MANIFEST_VERSION = "999"
    try:
        assert not is_compatible(store)
    finally:
        manifest_mod.MANIFEST_VERSION = "1"


def test_missing_manifest_means_first_run(tmp_path):
    assert load_manifest(tmp_path / "nope.db").entries == {}
    assert not is_compatible(tmp_path / "nope.db")


def test_cli_reports_no_change_on_second_run(dataset_factory, tmp_path, capsys):
    """CLI 侧的顺序陷阱：必须「先读旧、再算新、最后覆盖」。

    反了就是拿自己比自己，永远输出「无变更」——这种静默错误最难发现，
    所以用两次调用把它钉住。
    """
    from sync.__main__ import _report_changes

    class Args:
        manifest = None
        no_manifest = False

    class Report:
        source_id = "otaku"
        source_fingerprint = "fp"
        generated_at = "2026-10-28T00:00:00Z"

    path = dataset_factory("a.db", works=[("w1", "anime", "甲", None)])
    args, report = Args(), Report()

    _report_changes(args, report, str(path))
    assert "首次生成指纹" in capsys.readouterr().out

    _report_changes(args, report, str(path))
    assert "变更: 无" in capsys.readouterr().out


def test_export_cli_end_to_end(tmp_path, capsys):
    """走完整 CLI：argparse 参数 → 真实映射导出 → 生成指纹 → 第二次报「无变更」。

    单测只覆盖了 `_report_changes`，参数名写错或没接上照样会全绿。
    """
    from test_dataset import MAPPING, make_source

    from sync.__main__ import _run_dataset_export, build_parser

    source = make_source(tmp_path / "src.db")
    out = tmp_path / "ds.db"
    args = build_parser().parse_args(
        [
            "--export-dataset",
            "--source-db",
            str(source),
            "--mapping",
            str(MAPPING),
            "--dataset-out",
            str(out),
            "--no-snapshot",
        ]
    )

    assert _run_dataset_export(args) == 0
    captured = capsys.readouterr()
    assert "首次生成指纹" in captured.out
    assert (tmp_path / "ds.db.manifest.db").exists()

    assert _run_dataset_export(args) == 0
    assert "变更: 无" in capsys.readouterr().out
