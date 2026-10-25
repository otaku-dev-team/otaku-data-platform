"""命令行入口。

一条命令覆盖「跑哪些 → 跑 → 错在哪 → 跟上次比」，
需要门禁时加 `--gate`，需要看板时 `python -m devkit serve`。
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time

from . import cache, card, run, select, state

_NAMES = {"java": "Java", "py": "Python", "dart": "Dart"}


_TOOL_PREFIXES = ("scripts/", "devkit/")


def classify_extras(changed: list[str]) -> tuple[list[str], list[str]]:
    """分出「工具自身」和「完全没映射规则」的文件。

    这两类都不该静默吞掉：前者改了要手动验一下，后者是选跑规则没覆盖到的新目录——
    不吭声就等于默认「不用测」。
    """
    relevant = [
        path for path in changed
        if not path.startswith(select.IGNORED_PREFIXES)
        and not path.endswith(select.IGNORED_SUFFIXES)
    ]
    tooling = [path for path in relevant if path.startswith(_TOOL_PREFIXES)]
    unmapped = [
        path for path in relevant
        if not path.startswith(("backend-java/", "sync-python/", "app-client/", *_TOOL_PREFIXES))
        and path not in select.CONTRACT_FILES
        and path not in select.DEPENDENCY_MANIFESTS
    ]
    return tooling, unmapped


# --------------------------------------------------------------------------
# 计划展示
# --------------------------------------------------------------------------


def print_plan(plan: dict, base_note: str = "") -> None:
    if base_note:
        print(f"== 选跑（{base_note}）==")
    for stack in select.STACKS:
        entry = plan.get(stack)
        if not entry:
            continue
        name = _NAMES[stack]
        if entry["mode"] == "none":
            print(f"  {name}: 无相关测试")
            continue
        tag = "全量" if entry["mode"] == "all" else f"{len(entry['files'])} 个文件"
        print(f"  {name}: {tag}")
        if entry["mode"] == "all":
            for note in entry["notes"][-1:]:
                print(f"    {note}")
            continue
        for path in entry["files"]:
            print(f"    {path}  （{entry['reasons'].get(path, '')}）")
        for note in entry["notes"]:
            print(f"    ! {note}")
    for note in (plan.get("contract") or {}).values():
        print(f"  ! {note}")


# --------------------------------------------------------------------------
# 契约门禁：CI 会跑的那一步，本地提前跑掉
# --------------------------------------------------------------------------


def contract_check() -> dict:
    script = select.ROOT / "scripts" / "check-contract.py"
    spec = select.ROOT / "docs" / "openapi.yaml"
    if not script.exists():
        return {"status": "skipped", "detail": "没有 scripts/check-contract.py"}
    started = time.perf_counter()
    proc = subprocess.run(
        [sys.executable, str(script), str(spec)],
        cwd=str(select.ROOT), capture_output=True, text=True,
        encoding="utf-8", errors="replace",
    )
    seconds = round(time.perf_counter() - started, 1)
    if proc.returncode == 0:
        return {"status": "passed", "seconds": seconds, "detail": ""}
    tail = ((proc.stdout or "") + (proc.stderr or "")).strip().splitlines()
    return {"status": "failed", "seconds": seconds,
            "detail": tail[-1][:300] if tail else f"退出码 {proc.returncode}"}


# --------------------------------------------------------------------------
# 主流程
# --------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="devtest",
        description="按改动选跑测试 → 结构化失败卡片 → 与上次对比（三栈统一）",
        epilog="看板：python -m devkit serve --port 8787",
    )
    p.add_argument("files", nargs="*", help="改动文件；不传则自动取 git 改动")
    p.add_argument("--collect", action="store_true", help="只列选跑计划，不执行")
    p.add_argument("--all", action="store_true", help="三栈全量（慎用）")
    p.add_argument("--stack", choices=(*select.STACKS, "all"), default="all",
                   help="只处理一个栈（默认全部）")
    p.add_argument("--json", action="store_true", help="机器可读（stdout 只有 JSON）")
    p.add_argument("--inventory", action="store_true", help="三栈测试实时清点")
    p.add_argument("--rerun-failed", action="store_true",
                   help="只重跑上次失败的用例（精确到方法）")
    p.add_argument("--gate", action="store_true", help="跑测试 + 契约校验，等价于本地过一遍 CI")
    p.add_argument("--retry", type=int, default=0, metavar="N",
                   help="失败后只复跑失败用例 N 次，复跑通过则标记 flaky")
    p.add_argument("--slow", type=int, default=0, metavar="N", help="列出最慢的 N 个用例")
    p.add_argument("--no-cache", action="store_true", help="不用结果缓存")
    p.add_argument("--clear-cache", action="store_true", help="清空缓存后退出")
    p.add_argument("--no-parallel", action="store_true", help="多栈串行执行")
    p.add_argument("--context", type=int, default=3, metavar="N",
                   help="失败卡片里断言前后各带几行（默认 3）")
    p.add_argument("--stats", action="store_true", help="打印原始输出与卡片的字节数对比")
    p.add_argument("--verbose-tb", action="store_true", help="失败时附上完整堆栈（更啰嗦）")
    return p


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "serve":
        from . import server
        return server.main(argv[1:])

    args = build_parser().parse_args(argv)

    if args.clear_cache:
        print(f"已清空 {cache.clear()} 条缓存")
        return 0

    if args.inventory:
        data = select.inventory()
        for stack, item in data.items():
            extra = f"  ({item['note']})" if item.get("note") else ""
            print(f"{_NAMES[stack]:<7} {item['files']} 个文件 / {item['tests']} 项{extra}")
        return 0

    stacks = list(select.STACKS) if args.stack == "all" else [args.stack]
    options = run.Options(
        use_cache=not args.no_cache,
        retry=args.retry,
        parallel=not args.no_parallel,
        verbose=args.verbose_tb,
        context=args.context,
    )
    previous = state.previous_failures()
    base_note = ""
    changed: list[str] = []

    if args.rerun_failed:
        if not previous:
            print("上次没有失败用例，无需重跑。")
            return 0
        plan = {
            stack: {"mode": "files", "files": [], "reasons": {}, "notes": []}
            for stack, ids in previous.items() if ids and stack in stacks
        }
        options.methods = {stack: sorted(previous[stack]) for stack in plan}
        base_note = "上次失败的用例"
        if not plan:
            print("上次失败的用例都不在本次 --stack 范围内。")
            return 0
    else:
        if args.files:
            changed, base_note = list(args.files), "显式指定"
        else:
            changed, base_note = select.changed_files("origin/main")
        if not changed:
            if args.json:
                print(json.dumps({"changed": [], "conclusion": "empty"}, ensure_ascii=False))
            else:
                print(f"没有检测到改动（{base_note}）。确认无需测试可直接提交，或 --all 全量")
            return 0
        plan = select.build_plan(changed, stacks)
        if args.all:
            targets = select._run_targets()
            for stack in stacks:
                plan[stack] = {
                    "mode": "all",
                    "files": targets[stack],
                    "reasons": {path: "--all 指定全量" for path in targets[stack]},
                    "notes": [],
                }

    tooling, unmapped = classify_extras(changed)

    if args.collect:
        print_plan(plan, base_note)
        if tooling:
            names = "、".join(tooling[:3]) + ("…" if len(tooling) > 3 else "")
            print(f"  · 工具/脚本改动 {len(tooling)} 个（{names}）：无单测覆盖，改了请按用法手跑一次")
        for path in unmapped:
            print(f"  ! {path} 没有映射规则，拿不准请加 --all")
        return 0

    started = time.perf_counter()
    results = run.run_all(plan, options)
    elapsed = time.perf_counter() - started

    if not results:
        print("没有需要跑的测试。")
        return 0

    failures = run.collect_failures(results, previous, select.ROOT, args.context)
    gate = contract_check() if args.gate else None
    payload = run.build_payload(plan, results, failures, elapsed, argv)
    if gate:
        payload["gate"] = {"contract": gate}
    state.save(payload)

    contract_failed = bool(gate and gate["status"] == "failed")
    # 疑似不稳定也算失败：CI 不会重试，本地放过就是让 CI 去挂一次。
    unstable = [s for s, r in results.items() if r.get("status") == "flaky"]
    exit_code = 1 if (failures or contract_failed or unstable) else 0
    # 一个栈都没跑成（工具链都没有）时不能返回 0：那会被当成「测试通过了」。
    if not failures and not unstable and not any(
            r.get("status") != "skipped" for r in results.values()):
        exit_code = 2

    if args.json:
        print(json.dumps(_json_view(payload, exit_code), ensure_ascii=False, indent=2))
        return exit_code

    _print_human(payload, results, failures, gate, args)
    return exit_code


def _print_human(payload: dict, results: dict, failures: list[dict],
                 gate: dict | None, args) -> None:
    for stack in select.STACKS:
        result = results.get(stack)
        if not result:
            continue
        if result.get("status") == "skipped":
            print(f"{_NAMES[stack]:<6} {result.get('detail', '')}")
            continue
        rep = result.get("report")
        if rep is None:
            print(f"{_NAMES[stack]:<6} {result.get('detail', '')}")
            continue
        print(card.stack_line(rep, result.get("seconds", 0.0), bool(result.get("cached"))))
        if result.get("flaky"):
            print(f"       疑似不稳定：{len(result['flaky'])} 项首跑失败、复跑通过")

    for item in failures:
        print()
        for line in item["card"]:
            print(f"  {line}" if not line.startswith(("[FAIL]",)) else line)
        if item["badge"]:
            print(f"       {item['badge']}")
        if args.verbose_tb and item["message"]:
            print(f"       {item['message']}")

    if gate:
        word = "通过" if gate["status"] == "passed" else "未通过"
        detail = f"  {gate['detail']}" if gate.get("detail") else ""
        print(f"{'契约':<6} {word}  {gate.get('seconds', 0)}s{detail}")

    print()
    skipped = [_NAMES[s] for s in select.STACKS
               if (results.get(s) or {}).get("status") == "skipped"]
    ran = [_NAMES[s] for s in select.STACKS
           if results.get(s) and results[s].get("status") != "skipped"]
    unstable = [s for s in select.STACKS if (results.get(s) or {}).get("status") == "flaky"]
    if failures:
        new_count = sum(1 for f in failures if f["badge"] == "新增失败")
        print(f"结论：{len(failures)} 项失败（{new_count} 项新增）。"
              + ("契约校验未通过。" if gate and gate["status"] == "failed" else ""))
    elif gate and gate["status"] == "failed":
        print("结论：测试通过，但契约校验未通过。")
    elif skipped and not ran:
        print(f"结论：什么都没跑成（{'、'.join(skipped)} 都不可用），不等于通过。")
    elif unstable:
        print(f"结论：{'、'.join(_NAMES[s] for s in unstable)} 疑似不稳定（首跑失败、复跑通过）。"
              "CI 不会重试，这里按失败算。")
    elif skipped:
        print(f"结论：{'、'.join(ran)} 通过；{'、'.join(skipped)} 没执行（不算通过）。")
    else:
        print("结论：全部通过。可以提交。")

    if args.slow:
        for stack in select.STACKS:
            rep = (results.get(stack) or {}).get("report")
            if not rep:
                continue
            slowest = rep.slowest(args.slow)
            if slowest:
                print(f"最慢 {_NAMES[stack]}：" + "，".join(
                    f"{c.test_id} {c.seconds:.2f}s" for c in slowest))

    if args.stats:
        raw = sum(int(s.get("raw_bytes") or 0) for s in payload["stacks"].values())
        cards = sum(len("\n".join(f["card"])) for f in failures)
        if raw:
            print(f"输出对比：原始控制台 {raw} 字节 → 卡片 {cards} 字节"
                  f"（{raw / max(cards, 1):.1f}x）")
        else:
            print("输出对比：本次全部命中缓存，没有原始输出可比")

    history = state.history(3)
    if len(history) > 1:
        print(f"历史：最近 {len(history)} 次已记录（看板 python -m devkit serve）")


def _json_view(payload: dict, exit_code: int) -> dict:
    """给机器的那份：保留定位信息，去掉人类用的排版痕迹。"""
    return {
        "schema": payload.get("schema"),
        "conclusion": "failed" if exit_code else "passed",
        "ran_at": payload.get("ran_at"),
        "commit": payload.get("commit"),
        "elapsed": payload.get("elapsed"),
        "stacks": {
            name: {
                "status": s.get("status"),
                "cached": s.get("cached"),
                "total": s.get("total"),
                "passed": s.get("passed"),
                "failed": s.get("failed"),
                "skipped": s.get("skipped"),
                "seconds": s.get("seconds"),
                "source": s.get("source"),
                "note": s.get("note"),
                "flaky": s.get("flaky"),
            }
            for name, s in (payload.get("stacks") or {}).items()
        },
        "failures": [
            {
                "stack": f["stack"],
                "test": f["test_id"],
                "file": f["file"],
                "line": f["line"],
                "message": f["message"],
                "badge": f["badge"],
                "card": f["card"],
            }
            for f in payload.get("failures") or []
        ],
        "gate": payload.get("gate"),
    }
