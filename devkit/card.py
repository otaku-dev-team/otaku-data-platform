"""把失败渲染成一张卡片：让人和智能体都不用再去翻文件。

一张卡片承载三件事：**是哪一条**（测试名）、**在哪一行**（文件:行）、**错在哪**
（断言消息 + 出错位置前后几行源码）。这三样齐了，改代码可以直接动手；少任何一样，
读者就得去打开文件自己找——那正是 v1 最费 token 的地方。
"""

from __future__ import annotations

from pathlib import Path

from .report import Case, Failure, StackReport
from .select import STACK_LABELS

_CONTEXT = 3          # 断言前后各带几行：多了是噪音，少了看不出意图
_MAX_MESSAGE = 200


def _read_window(path: Path, line: int, context: int) -> list[tuple[int, str]]:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
    start = max(1, line - context)
    end = min(len(lines), line + context)
    return [(no, lines[no - 1]) for no in range(start, end + 1)]


def render_failure(case: Case, root: Path, context: int = _CONTEXT) -> list[str]:
    failure: Failure = case.failure or Failure()
    # 终端一律用 ASCII 记号：Windows 的 cmd 可能是 GBK，✗/✓ 打不出来会直接抛异常
    lines = [f"[FAIL] {case.test_id}"]

    where = ""
    if failure.file:
        rel = failure.file
        if rel.startswith(root.as_posix() + "/"):
            rel = rel[len(root.as_posix()) + 1:]
        else:
            try:
                rel = Path(rel).resolve().relative_to(root).as_posix()
            except (ValueError, OSError):
                pass
        where = f"{rel}:{failure.line}" if failure.line else rel
        lines.append(f"  {where}")

    message = (failure.message or "").strip().replace("\n", " ")
    if len(message) > _MAX_MESSAGE:
        message = message[:_MAX_MESSAGE] + " …"
    if message:
        lines.append(f"  {message}")

    if failure.file and failure.line:
        window = _read_window(Path(failure.file), int(failure.line), context)
        width = len(str(window[-1][0])) if window else 1
        for no, text in window:
            marker = ">" if no == int(failure.line) else " "
            lines.append(f"   {marker} {no:>{width}} | {text.rstrip()}")
    return lines


def badge(case: Case, previous: set[str]) -> str:
    """这条失败是不是这轮新出现的。措辞留余地：依赖闭包不完美，不下结论。"""
    if case.test_id in previous:
        return "上次也失败"
    return "新增失败"


def stack_line(report: StackReport, seconds: float, cached: bool = False) -> str:
    name = STACK_LABELS.get(report.stack, report.stack)
    if cached:
        return f"{name:<6} 跳过（同一状态上次已通过，{report.passed}/{report.total}）"
    if report.source == "console":
        return f"{name:<6} {report.total} 条失败线索  {seconds:.1f}s  ← 控制台兜底（无结构化报告）"
    parts = [f"{name:<6} {report.total} 项"]
    if report.failed:
        parts.append(f"{report.failed} 失败")
    if report.skipped:
        parts.append(f"{report.skipped} 跳过")
    parts.append(f"{seconds:.1f}s")
    if report.note:
        parts.append(f"（{report.note}）")
    return "  ".join(parts)
