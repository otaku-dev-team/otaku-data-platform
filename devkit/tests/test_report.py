"""报告解析。

这两块各自对应一个曾经踩过的真坑：
- junitxml 里能不能还原「文件:行」——还原不出来，失败卡片就等于白做；
- surefire 会不会把上次的旧报告当成本次结果——那是典型的假绿。
"""

import os
import time

from devkit import report, select

_PY_JUNIT = """<?xml version="1.0" encoding="utf-8"?>
<testsuites>
  <testsuite name="tests.test_importer" tests="2" errors="0" failures="1">
    <testcase classname="tests.test_importer" name="test_ok" time="0.01"/>
    <testcase classname="tests.test_importer" name="test_bad" time="0.02">
      <failure message="assert 1 == 2">sync-python/tests/test_importer.py:12: AssertionError</failure>
    </testcase>
  </testsuite>
</testsuites>
"""

_JAVA_SUITE = """<?xml version="1.0" encoding="utf-8"?>
<testsuite name="com.otaku.SomeTest" tests="1" errors="0" failures="0">
  <testcase classname="com.otaku.SomeTest" name="testSomething" time="0.10"/>
</testsuite>
"""


def test_junit_xml_extracts_file_and_line(tmp_path):
    path = tmp_path / "report.xml"
    path.write_text(_PY_JUNIT, encoding="utf-8")

    rep = report.parse_junit_xml(path, "py", select.PY_DIR)

    assert len(rep.cases) == 2
    failed = rep.failures()
    assert len(failed) == 1
    failure = failed[0].failure
    assert failure is not None
    assert failure.file.endswith("test_importer.py")
    assert failure.line == 12
    assert failure.message


def test_junit_xml_self_stack_keeps_repo_relative_id(tmp_path):
    """工具栈的用例 id 要能直接喂回 pytest（`路径::函数`），否则重跑对不上。"""
    path = tmp_path / "report.xml"
    path.write_text(_PY_JUNIT, encoding="utf-8")

    rep = report.parse_junit_xml(path, "self", select.ROOT)

    ids = [case.test_id for case in rep.cases]
    assert all("::" in test_id for test_id in ids)


def test_surefire_ignores_stale_reports(tmp_path):
    stale = tmp_path / "TEST-Stale.xml"
    stale.write_text(_JAVA_SUITE, encoding="utf-8")
    os.utime(stale, (1_000_000, 1_000_000))   # 很久以前写的

    rep = report.parse_surefire(tmp_path, tmp_path, since=time.time())

    assert rep.cases == []


def test_surefire_keeps_fresh_reports(tmp_path):
    fresh = tmp_path / "TEST-Fresh.xml"
    fresh.write_text(_JAVA_SUITE, encoding="utf-8")

    rep = report.parse_surefire(tmp_path, tmp_path, since=time.time() - 60)

    assert len(rep.cases) == 1
