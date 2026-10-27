"""命令拼装、改动分类与缓存键。

这几处坏掉的后果都不是「报错」，而是「看起来跑过了」——最贵的那种故障。
"""

import sys

from devkit import cache, cli, select


def test_names_cover_every_stack():
    """加了新栈却忘了显示名，输出会在 `_NAMES[stack]` 上 KeyError。"""
    assert set(select.STACKS) == set(cli._NAMES)


def test_devkit_source_is_not_reported_as_uncovered():
    """devkit 的 .py 现在由「工具」栈自己跑，不能再说「无单测覆盖」。

    原来那句话等于告诉使用者「跑 devtest 也白跑」，正是它把工具改动推到了
    验证流程之外。
    """
    tooling, _ = cli.classify_extras(["devkit/select.py"])
    assert tooling == []


def test_scripts_still_reported_as_uncovered():
    tooling, _ = cli.classify_extras(["scripts/smoke.py"])
    assert tooling == ["scripts/smoke.py"]


def test_unknown_directory_is_reported_as_unmapped():
    _, unmapped = cli.classify_extras(["newtool/thing.py"])
    assert "newtool/thing.py" in unmapped


def test_self_command_runs_from_repo_root():
    cmd, cwd = select._command(
        "self", ["devkit/tests/test_select.py"], False, [sys.executable],
        junit_xml="report.xml")

    assert cwd == select.ROOT
    assert "devkit/tests/test_select.py" in cmd


def test_self_full_run_still_narrows_to_tests_dir():
    """全量时必须显式给路径。

    工作目录是仓库根，pytest 不传路径会顺着往下把 sync-python/tests 也收进来——
    「跑工具栈」变成「跑了半个仓库」，而且没人看得出来。
    """
    cmd, _ = select._command("self", [], True, [sys.executable])

    assert "devkit/tests" in cmd


def test_cache_key_ignores_random_report_path():
    """junitxml 文件名每次随机，直接参与哈希会让缓存永不命中。"""
    first = cache.make_key(
        "py", ["pytest", "--junitxml=devkit/.state/tmp/a1b2.xml"], ["tests/test_x.py"],
        select.PY_DIR)
    second = cache.make_key(
        "py", ["pytest", "--junitxml=devkit/.state/tmp/c3d4.xml"], ["tests/test_x.py"],
        select.PY_DIR)

    assert first == second


def test_cache_key_changes_with_selected_files():
    one = cache.make_key("py", ["pytest"], ["tests/test_a.py"], select.PY_DIR)
    two = cache.make_key("py", ["pytest"], ["tests/test_b.py"], select.PY_DIR)

    assert one != two
