"""把三栈的测试报告归一化成同一套结构。

**为什么读报告文件而不读控制台**：三个栈本来就在磁盘上产出机器可读报告——
Java 是 surefire 默认就会写的 `target/surefire-reports/TEST-*.xml`，pytest 加
`--junitxml` 即可（核心功能，不用装插件），Dart 用 `--reporter json`。这比正则过滤
控制台输出强在三点：失败列表完整（不被尾巴截断）、带精确到文件行号、带每个用例耗时。
而且不受 `-q`、日志重定向、系统语言影响。

拿不到报告时（工具链老、输出被吞），`console_fallback()` 退回 v1 的文本裁剪，
并显式标注「来源：console」，不假装结构化。
"""

from __future__ import annotations

import json
import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

# --------------------------------------------------------------------------
# 数据结构
# --------------------------------------------------------------------------


@dataclass
class Failure:
    message: str = ""          # 一行结论，例如 "expected: <x> but was: <y>"
    detail: str = ""           # 原始堆栈/断言块，按需截断
    file: str = ""             # 仓库相对路径（拿得到才填）
    line: int | None = None


@dataclass
class Case:
    test_id: str
    status: str                # passed / failed / error / skipped
    seconds: float = 0.0
    failure: Failure | None = None

    @property
    def failed(self) -> bool:
        return self.status in ("failed", "error")


@dataclass
class StackReport:
    stack: str
    cases: list[Case] = field(default_factory=list)
    source: str = ""           # surefire-xml / junit-xml / dart-json / console
    note: str = ""

    @property
    def total(self) -> int:
        return len(self.cases)

    @property
    def passed(self) -> int:
        return sum(1 for c in self.cases if c.status == "passed")

    @property
    def failed(self) -> int:
        return sum(1 for c in self.cases if c.failed)

    @property
    def skipped(self) -> int:
        return sum(1 for c in self.cases if c.status == "skipped")

    @property
    def seconds(self) -> float:
        return round(sum(c.seconds for c in self.cases), 3)

    def failures(self) -> list[Case]:
        return [c for c in self.cases if c.failed]

    def slowest(self, n: int = 5) -> list[Case]:
        return sorted(self.cases, key=lambda c: c.seconds, reverse=True)[:n]


# --------------------------------------------------------------------------
# 文件定位：报告只给类名，得自己找回仓库里的路径
# --------------------------------------------------------------------------

_PY_FILE_LINE = re.compile(r"([\w./\\-]+\.py):(\d+)")
_JAVA_FILE_LINE = re.compile(r"\(([\w$]+\.java):(\d+)\)")


def _java_index(roots: list[Path]) -> dict[str, str]:
    """文件名 → 仓库相对路径。报告里只有 `LikePatternTest.java`，没有目录。"""
    index: dict[str, str] = {}
    for root in roots:
        if not root.exists():
            continue
        for path in root.rglob("*.java"):
            index.setdefault(path.name, path.as_posix())
    return index


def _py_module_to_path(classname: str, base: Path) -> str:
    """`tests.test_cleaning` → `sync-python/tests/test_cleaning.py`。"""
    rel = classname.replace(".", "/") + ".py"
    candidate = base / rel
    if candidate.exists():
        return candidate.as_posix()
    # 非包结构（rootdir 不同）时退化成按文件名找
    for path in base.rglob(Path(rel).name):
        return path.as_posix()
    return ""


def _first_line(text: str) -> str:
    for line in (text or "").splitlines():
        if line.strip():
            return line.strip()
    return ""


# --------------------------------------------------------------------------
# JUnit XML：pytest 与 surefire 共用同一套 schema，分开解析只因路径还原方式不同
# --------------------------------------------------------------------------


def _parse_junit_like(path: Path, stack: str, base: Path, java_roots: list[Path]) -> list[Case]:
    tree = ET.parse(str(path))
    root = tree.getroot()
    suites = [root] if root.tag == "testsuite" else list(root.iter("testsuite"))
    java_files: dict[str, str] = {}
    cases: list[Case] = []

    for suite in suites:
        for node in suite.iter("testcase"):
            classname = node.get("classname") or suite.get("name") or ""
            name = node.get("name") or ""
            seconds = float(node.get("time") or 0.0)

            status = "passed"
            failure: Failure | None = None
            for child in node:
                tag = child.tag
                if tag in ("failure", "error"):
                    status = "failed" if tag == "failure" else "error"
                    message = _first_line(child.get("message") or "")
                    body = (child.text or "").strip()
                    file, line = _locate(stack, classname, body, base, java_roots, java_files)
                    if not message:
                        message = _first_line(body)
                    failure = Failure(message=message, detail=body[:2000], file=file, line=line)
                    break
                if tag == "skipped":
                    status = "skipped"

            if stack == "java":
                simple = classname.rsplit(".", 1)[-1]
                test_id = f"{simple}#{name}"
            else:
                file_rel = _py_module_to_path(classname, base)
                short = file_rel.replace(base.as_posix() + "/", "") if file_rel else classname
                test_id = f"{short}::{name}"

            cases.append(Case(test_id=test_id, status=status, seconds=seconds, failure=failure))
    return cases


def _locate(
    stack: str, classname: str, body: str,
    base: Path, java_roots: list[Path], java_cache: dict[str, str],
) -> tuple[str, int | None]:
    """从断言/堆栈文本里抠出「仓库相对路径 + 行号」。抠不到就返回空，不猜。"""
    if stack == "java":
        match = _JAVA_FILE_LINE.search(body or "")
        if not match:
            return "", None
        java_name, line = match.group(1), int(match.group(2))
        if not java_cache:
            java_cache.update(_java_index(java_roots))
        return java_cache.get(java_name, ""), line

    # Python：取最后一个 `xxx.py:12` —— 最靠近断言的是它自己
    hits = _PY_FILE_LINE.findall(body or "")
    if not hits:
        return "", None
    raw, line = hits[-1]
    rel = raw.replace("\\", "/")
    for prefix in (base.as_posix() + "/", "./"):
        if rel.startswith(prefix):
            rel = rel[len(prefix):]
    candidate = base / rel
    if candidate.exists():
        return candidate.as_posix(), int(line)
    # traceback 里可能只有文件名的一部分（比如相对 rootdir 的路径）
    for path in base.rglob(Path(rel).name):
        return path.as_posix(), int(line)
    return "", int(line)


def parse_junit_xml(path: Path, stack: str, base: Path) -> StackReport:
    """pytest 的 `--junitxml` 产物。"""
    java_roots = [base / "src/test/java", base / "src/main/java"]
    cases = _parse_junit_like(path, stack, base, java_roots)
    return StackReport(stack=stack, cases=cases, source="junit-xml")


def parse_surefire(report_dir: Path, java_base: Path, since: float | None = None) -> StackReport:
    """Surefire 每次 `mvn test` 都会写，不需要额外配置。

    `since` 是本次运行的开始时间戳：`-Dtest=X` 只会重写 X 的报告，**其余旧报告仍在**。
    不按 mtime 过滤就会把上一次的结果当成本次结果——这是最容易踩的一个假绿。
    """
    roots = [java_base / "src/test/java", java_base / "src/main/java"]
    files = sorted(report_dir.glob("TEST-*.xml")) if report_dir.exists() else []
    if since is not None:
        fresh = []
        for path in files:
            try:
                if path.stat().st_mtime >= since - 1.0:   # 1 秒容差：文件时间精度
                    fresh.append(path)
            except OSError:
                continue
        files = fresh
    if not files:
        return StackReport(stack="java", source="surefire-xml",
                           note="没有本次运行产出的 surefire 报告")
    cases: list[Case] = []
    for path in files:
        try:
            cases.extend(_parse_junit_like(path, "java", java_base, roots))
        except ET.ParseError as exc:  # 报告被写坏（进程被杀），不该让整体挂掉
            return StackReport(stack="java", source="surefire-xml",
                               note=f"报告解析失败 {path.name}: {exc}")
    return StackReport(stack="java", cases=cases, source="surefire-xml")


# --------------------------------------------------------------------------
# Dart：`flutter test --reporter json` 是 JSON 行事件流
# --------------------------------------------------------------------------


def parse_dart_json(text: str, base: Path) -> StackReport:
    started: dict[int, dict] = {}
    errors: dict[int, Failure] = {}
    cases: list[Case] = []
    parsed_any = False

    for line in (text or "").splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = event.get("type")
        if kind == "testStart":
            parsed_any = True
            test = event.get("test") or {}
            started[int(event.get("testID") or test.get("id") or 0)] = test
        elif kind == "error":
            parsed_any = True
            tid = int(event.get("testID") or 0)
            url = (started.get(tid) or {}).get("url") or ""
            errors[tid] = Failure(
                message=event.get("error") or "测试出错",
                detail=(event.get("stackTrace") or "")[:2000],
                file=_dart_url_to_path(url, base),
                line=(started.get(tid) or {}).get("line"),
            )
        elif kind == "testDone":
            parsed_any = True
            tid = int(event.get("testID") or 0)
            test = started.get(tid) or {}
            # 隐式测试（浏览器/加载用例）没有 url，跳过，免得混进正常用例里
            if event.get("hidden"):
                continue
            status = "skipped" if event.get("skipped") else (
                "passed" if event.get("result") == "success" else "failed")
            cases.append(Case(
                test_id=str(test.get("name") or f"#{tid}"),
                status=status,
                seconds=float(event.get("time") or 0) / 1000.0,
                failure=errors.get(tid),
            ))

    if not parsed_any:
        return StackReport(stack="dart", source="dart-json", note="没有解析到 dart 的 JSON 事件")
    return StackReport(stack="dart", cases=cases, source="dart-json")


def _dart_url_to_path(url: str, base: Path) -> str:
    if not url:
        return ""
    raw = url
    if raw.startswith("file://"):
        raw = raw[len("file://"):]
        if re.match(r"^/[A-Za-z]:", raw):  # file:///D:/... → D:/...
            raw = raw[1:]
    raw = raw.replace("\\", "/")
    if base.as_posix() in raw:
        return raw
    marker = "/test/"
    if marker in raw:
        return (base.as_posix() + "/test/" + raw.split(marker, 1)[1])
    return raw


# --------------------------------------------------------------------------
# 兜底：实在拿不到结构化报告时，退回文本裁剪（并明确标注来源）
# --------------------------------------------------------------------------


_CONSOLE_KEEP = (
    re.compile(r"Tests run:|<<< (FAILURE|ERROR)|BUILD (SUCCESS|FAILURE)"),
    re.compile(r"^(FAILED|ERROR) |\d+ (passed|failed|error)"),
    re.compile(r"All tests passed|Some tests failed|\+\d+ -\d+"),
)


def console_fallback(stack: str, output: str, note: str = "") -> StackReport:
    lines = [line.rstrip() for line in (output or "").splitlines() if line.strip()]
    kept = []
    for line in lines:
        if any(pattern.search(line) for pattern in _CONSOLE_KEEP):
            kept.append(Case(test_id=line.strip()[:160], status="failed", seconds=0.0))
    return StackReport(
        stack=stack, cases=kept, source="console",
        note=note or "没有结构化报告，只能用控制台文本（信息不完整）",
    )
