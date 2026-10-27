"""执行层：跑命令 → 解析报告 → 渲染卡片 → 记状态。

和 `select.py` 的分工：那边只回答「跑哪些」，这边只管「怎么跑、怎么读结果」。
分开的原因是两者改动的频率和原因完全不同——选跑逻辑稳定，报告解析要跟着工具链变。
"""

from __future__ import annotations

import concurrent.futures as futures
import subprocess
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path

from . import card, cache, report, select, state
from .report import StackReport

# 缓存指纹按「该栈所有源码」算。self 用 devkit 而非仓库根：
# 拿 ROOT 当基准会把 backend-java / app-client 全哈希进来，几万文件且过度失效。
STACK_DIR = {
    "java": select.JAVA_DIR, "py": select.PY_DIR,
    "dart": select.DART_DIR, "self": select.DEVKIT_DIR,
}
TMP = cache.STATE_DIR / "tmp"


@dataclass
class Options:
    use_cache: bool = True
    retry: int = 0
    parallel: bool = True
    verbose: bool = False
    context: int = 3
    # stack -> 精确用例 id。给了就只跑这些（`--rerun-failed`）
    methods: dict[str, list[str]] = field(default_factory=dict)


def _invoke(cmd: list[str], cwd: Path) -> tuple[int, str, float]:
    started = time.perf_counter()
    proc = subprocess.run(
        cmd, cwd=str(cwd), capture_output=True, text=True,
        encoding="utf-8", errors="replace",
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or ""), time.perf_counter() - started


def _parse(stack: str, output: str, junit_path: str | None, started_at: float,
           exit_code: int) -> StackReport:
    """报告优先，控制台兜底。兜底时明确标注来源，不假装结构化。"""
    parsed: StackReport | None = None
    if stack == "java":
        parsed = report.parse_surefire(
            select.JAVA_DIR / "target" / "surefire-reports", select.JAVA_DIR, since=started_at)
    elif stack in ("py", "self"):
        # 两者的报告格式一样，差别只在于「路径相对谁」：py 相对 sync-python，
        # 工具自身的测试相对仓库根。传错 base 会让文件:行错位。
        base = select.PY_DIR if stack == "py" else select.ROOT
        if junit_path and Path(junit_path).exists():
            parsed = report.parse_junit_xml(Path(junit_path), stack, base)
    else:
        parsed = report.parse_dart_json(output, select.DART_DIR)

    if parsed is not None and parsed.cases:
        return parsed
    if exit_code == 0:
        # 退出码 0 且没有用例：多半是「选到的文件里没有测试」，不该编造失败线索
        return parsed or StackReport(stack=stack, source="empty", note="没有执行到用例")
    return report.console_fallback(stack, output, note=(parsed.note if parsed else ""))


def _report_to_dict(rep: StackReport) -> dict:
    return {
        "source": rep.source,
        "note": rep.note,
        "cases": [
            {
                "id": c.test_id, "status": c.status, "s": c.seconds,
                "msg": c.failure.message if c.failure else "",
                "detail": c.failure.detail if c.failure else "",
                "file": c.failure.file if c.failure else "",
                "line": c.failure.line if c.failure else None,
            }
            for c in rep.cases
        ],
    }


def _report_from_dict(stack: str, data: dict) -> StackReport:
    rep = StackReport(stack=stack, source=data.get("source", ""), note=data.get("note", ""))
    for item in data.get("cases") or []:
        failure = None
        if item.get("msg") or item.get("detail") or item.get("file"):
            failure = report.Failure(
                message=item.get("msg", ""), detail=item.get("detail", ""),
                file=item.get("file", ""), line=item.get("line"),
            )
        rep.cases.append(report.Case(
            test_id=item.get("id", ""), status=item.get("status", "passed"),
            seconds=float(item.get("s") or 0), failure=failure,
        ))
    return rep


def _retry_methods(stack: str, failed: list[report.Case]) -> dict:
    """把失败用例换成「只跑它」的入参。py/self 走文件参数，java/dart 走 methods。"""
    ids = [case.test_id for case in failed]
    if stack == "py":
        return {"files": [f"sync-python/{i}" for i in ids]}
    if stack == "self":
        # test_id 已经是相对仓库根的 `devkit/tests/x.py::test_y`
        return {"files": ids}
    return {"methods": ids}


def run_stack(stack: str, entry: dict, opts: Options) -> dict:
    toolchain, reason = select.toolchain_detail(stack)
    if toolchain is None:
        return {"status": "skipped", "detail": f"跳过（不算通过）：{reason}",
                "stack": stack, "cached": False}

    files = list(entry.get("files") or [])
    full = entry.get("mode") == "all"
    methods = opts.methods.get(stack) or []

    if stack in ("py", "self") and methods:
        prefix = "sync-python/" if stack == "py" else ""
        files = [f"{prefix}{m}" for m in methods]
        full = False
        methods = []
    if not full and not files and not methods:
        return {"status": "skipped", "detail": "没有相关测试文件", "stack": stack, "cached": False}

    junit_path = None
    if stack in ("py", "self"):
        TMP.mkdir(parents=True, exist_ok=True)
        junit_path = str(TMP / f"pytest-{uuid.uuid4().hex[:8]}.xml")

    cmd, cwd = select._command(
        stack, files, full, toolchain,
        junit_xml=junit_path,
        dart_json=(stack == "dart"),
        methods=methods or None,
    )

    key = cache.make_key(stack, cmd, files, STACK_DIR[stack])
    if opts.use_cache and not methods:
        hit = cache.load(key)
        if hit and hit.get("status") == "passed":
            rep = _report_from_dict(stack, hit["report"])
            return {
                "status": "passed", "stack": stack, "cached": True,
                "seconds": 0.0, "command": " ".join(cmd),
                "report": rep, "raw_bytes": 0, "card_bytes": 0,
            }

    started_at = time.time()
    exit_code, output, elapsed = _invoke(cmd, cwd)
    rep = _parse(stack, output, junit_path, started_at, exit_code)
    if junit_path:
        Path(junit_path).unlink(missing_ok=True)   # 报告只是中转，别在 .state 里堆着

    flaky: list[str] = []
    if exit_code != 0 and opts.retry > 0 and rep.failed:
        for _ in range(opts.retry):
            failed_ids = [case.test_id for case in rep.failures()]
            again = _retry_methods(stack, rep.failures())
            retry_files = again.get("files", files)
            retry_methods = again.get("methods", [])
            retry_junit = None
            if stack in ("py", "self"):
                retry_junit = str(TMP / f"pytest-{uuid.uuid4().hex[:8]}.xml")
            retry_cmd, retry_cwd = select._command(
                stack, retry_files, False, toolchain,
                junit_xml=retry_junit, dart_json=(stack == "dart"),
                methods=retry_methods or None,
            )
            code2, out2, _ = _invoke(retry_cmd, retry_cwd)
            rep2 = _parse(stack, out2, retry_junit, time.time(), code2)
            if code2 == 0:
                flaky.extend(failed_ids)
                rep = rep2
                exit_code = 0
                break

    status = "passed" if exit_code == 0 else "failed"
    if flaky and status == "passed":
        status = "flaky"

    result = {
        "status": status, "stack": stack, "cached": False,
        "seconds": round(elapsed, 1), "command": " ".join(cmd),
        "report": rep, "raw_bytes": len(output.encode("utf-8")),
        "card_bytes": 0, "flaky": flaky, "exit_code": exit_code,
    }
    if status == "passed" and not methods:
        cache.save(key, {"status": "passed", "stack": stack, "report": _report_to_dict(rep)})
    return result


def run_all(plan: dict, opts: Options) -> dict[str, dict]:
    """按栈执行。多栈并行——三个栈互不共享资源，串行等它们只是浪费墙钟时间。"""
    stacks = [s for s in select.STACKS if plan.get(s)]
    if not stacks:
        return {}

    if opts.parallel and len(stacks) > 1:
        results: dict[str, dict] = {}
        with futures.ThreadPoolExecutor(max_workers=len(stacks)) as pool:
            jobs = {pool.submit(run_stack, s, plan[s], opts): s for s in stacks}
            for job in futures.as_completed(jobs):
                stack = jobs[job]
                try:
                    results[stack] = job.result()
                except Exception as exc:   # 单个栈炸掉不该带走另外两个
                    results[stack] = {"status": "failed", "stack": stack, "cached": False,
                                      "detail": f"执行异常：{type(exc).__name__}: {exc}",
                                      "report": StackReport(stack=stack, source="error")}
        return {s: results[s] for s in select.STACKS if s in results}

    return {s: run_stack(s, plan[s], opts) for s in stacks}


def collect_failures(results: dict[str, dict], previous: dict[str, set[str]],
                     root: Path, context: int = 3) -> list[dict]:
    """把失败摊平成 UI/JSON/终端共用的结构，卡片文本在这里一次性渲染好。"""
    out: list[dict] = []
    for stack, result in results.items():
        rep = result.get("report")
        if not rep:
            continue
        for case in rep.failures():
            lines = card.render_failure(case, root, context)
            # 状态里只存仓库相对路径：UI 与别人的机器都不该看到本机绝对路径
            rel_file = case.failure.file if case.failure else ""
            try:
                rel_file = Path(rel_file).resolve().relative_to(root).as_posix() if rel_file else ""
            except (ValueError, OSError):
                pass
            if rep.source == "console":
                lines = [f"[FAIL] {case.test_id}"] + lines[1:]
            out.append({
                "stack": stack,
                "test_id": case.test_id,
                "message": case.failure.message if case.failure else "",
                "file": rel_file,
                "line": case.failure.line if case.failure else None,
                "badge": card.badge(case, previous.get(stack, set())),
                "source": rep.source,
                "card": lines,
            })
    return out


def build_payload(plan: dict, results: dict[str, dict], failures: list[dict],
                  elapsed: float, args: list[str]) -> dict:
    """写进 state 的那份数据。UI 只读它，不再二次请求源码。"""
    stacks = {}
    for stack, result in results.items():
        rep: StackReport | None = result.get("report")
        stacks[stack] = {
            "status": result.get("status"),
            "cached": bool(result.get("cached")),
            "seconds": result.get("seconds", 0.0),
            "command": result.get("command", ""),
            "detail": result.get("detail", ""),
            "total": rep.total if rep else 0,
            "passed": rep.passed if rep else 0,
            "failed": rep.failed if rep else 0,
            "skipped": rep.skipped if rep else 0,
            "source": rep.source if rep else "",
            "note": rep.note if rep else "",
            "slowest": [
                {"id": c.test_id, "seconds": round(c.seconds, 3)}
                for c in (rep.slowest(5) if rep else [])
            ],
            "flaky": result.get("flaky") or [],
            "raw_bytes": result.get("raw_bytes", 0),
        }
    return {
        "ran_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "commit": state.git_state(),
        "elapsed": round(elapsed, 1),
        "args": args,
        "stacks": stacks,
        "failures": failures,
        "selection": {
            stack: {
                "mode": plan[stack].get("mode"),
                "files": plan[stack].get("files") or [],
                "notes": plan[stack].get("notes") or [],
            }
            for stack in plan if stack in select.STACKS
        },
    }
