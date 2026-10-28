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
import unicodedata

from . import cache, card, run, select, state

_NAMES = select.STACK_LABELS


_TOOL_PREFIXES = ("scripts/", "devkit/")

# 改了这些不会映射到任何单测，但会改线上行为：devkit 选不到，得交给部署后的 smoke。
# 不吭声的话，开发者看到「无相关测试」会以为自己安全了。
_DEPLOY_TOUCH = (
    "backend-java/src/main/resources/application",
    "backend-java/compose",
    "backend-java/.env",
    "backend-java/Dockerfile",
    ".github/workflows/",
    "docs/deploy",
)

_GATE_LABELS = {"contract": "契约", "site-isolation": "站点隔离"}


def deploy_touching(changed: list[str]) -> list[str]:
    """改动里会影响线上行为、但选不到测试的那部分（配置 / 部署 / CI）。"""
    return [path for path in changed if path.startswith(_DEPLOY_TOUCH)]


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
    # devkit 的 .py 现在由「工具」那一栈自己跑测试，不再算「无单测覆盖」。
    # 以前这里把它一并算进来，等于告诉使用者「跑了也白跑」——正是这句提示
    # 让人（和智能体）放弃用 devtest 验证工具改动。
    tooling = [
        path for path in relevant
        if path.startswith(_TOOL_PREFIXES) and not select.is_devkit_source(path)
    ]
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


def _script_check(script: str, argv: list[str] | None = None) -> dict:
    """跑 `scripts/` 下的一个守卫脚本，返回统一形状。

    这些脚本 CI 也会跑；本地提前跑掉，是为了别等 push 上去才知道红。
    """
    path = select.ROOT / script
    if not path.exists():
        return {"status": "skipped", "detail": f"没有 {script}"}
    started = time.perf_counter()
    proc = subprocess.run(
        [sys.executable, str(path), *(argv or [])],
        cwd=str(select.ROOT), capture_output=True, text=True,
        encoding="utf-8", errors="replace",
    )
    seconds = round(time.perf_counter() - started, 1)
    if proc.returncode == 0:
        return {"status": "passed", "seconds": seconds, "detail": ""}
    tail = ((proc.stdout or "") + (proc.stderr or "")).strip().splitlines()
    return {"status": "failed", "seconds": seconds,
            "detail": tail[-1][:300] if tail else f"退出码 {proc.returncode}"}


def contract_check() -> dict:
    return _script_check("scripts/check-contract.py",
                         [str(select.ROOT / "docs" / "openapi.yaml")])


def site_isolation_check() -> dict:
    """核心代码零硬编码站名——CI 有同名 workflow，写死站名/IP 会红。"""
    return _script_check("scripts/check-site-isolation.py")


def run_gate() -> dict:
    """本地门禁：CI 会跑、且本机秒级能跑完的守卫。

    需要 docker（deploy-lint）或 Flutter（flutter analyze）的不在此列——
    本地跑不动的写进来只会变成永远「跳过」的装饰。
    """
    return {
        "contract": contract_check(),
        "site-isolation": site_isolation_check(),
    }


def gate_failures(gate: dict | None) -> list[str]:
    return [name for name, item in (gate or {}).items()
            if item.get("status") == "failed"]


def _pad(text: str, width: int) -> str:
    """按终端显示宽度补空格：CJK 占两格，否则「契约」和「站点隔离」这一列对不齐。"""
    shown = sum(2 if unicodedata.east_asian_width(ch) in "WF" else 1 for ch in text)
    return text + " " * max(0, width - shown)


def print_gate(gate: dict) -> None:
    for name, item in gate.items():
        word = {"passed": "通过", "failed": "未通过"}.get(item["status"], "跳过")
        detail = f"  {item['detail']}" if item.get("detail") else ""
        label = _pad(_GATE_LABELS.get(name, name), 10)
        print(f"{label} {word}  {item.get('seconds', 0)}s{detail}")


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
    p.add_argument("--gate", action="store_true",
                   help="跑测试 + 本机可跑的 CI 守卫（契约、站点隔离）")
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
    deploy = deploy_touching(changed)

    if args.collect:
        print_plan(plan, base_note)
        if tooling:
            names = "、".join(tooling[:3]) + ("…" if len(tooling) > 3 else "")
            print(f"  · 脚本改动 {len(tooling)} 个（{names}）：devtest 覆盖不到，改完请单独手跑一次")
        for path in unmapped:
            print(f"  ! {path} 没有映射规则，拿不准请加 --all")
        if deploy:
            print(f"  · 配置/部署改动 {len(deploy)} 个：devkit 选不到这部分的测试，"
                  "部署后用 python scripts/smoke.py --base-url <地址> 验")
        return 0

    started = time.perf_counter()
    results = run.run_all(plan, options)
    elapsed = time.perf_counter() - started

    # 门禁先跑：只改配置/部署时选不到任何测试，但门禁依然该过一遍，
    # 否则这类改动会把 gate 一起跳过。
    gate = run_gate() if args.gate else None
    gate_failed = gate_failures(gate)

    if not results:
        print("没有需要跑的测试。")
        if deploy:
            print(f"  · 但改了 {len(deploy)} 个配置/部署文件，devkit 管不到这部分——"
                  "部署后用 smoke 验：")
            print("      python scripts/smoke.py --base-url <地址>")
        if gate:
            print()
            print_gate(gate)
            print()
            if gate_failed:
                print(f"结论：{'、'.join(_GATE_LABELS.get(n, n) for n in gate_failed)}未通过。")
                return 1
            print("结论：门禁通过。")
        return 0

    failures = run.collect_failures(results, previous, select.ROOT, args.context)
    payload = run.build_payload(plan, results, failures, elapsed, argv)
    if gate:
        payload["gate"] = gate
    if deploy:
        payload["deploy_touch"] = deploy
    state.save(payload)

    # 疑似不稳定也算失败：CI 不会重试，本地放过就是让 CI 去挂一次。
    unstable = [s for s, r in results.items() if r.get("status") == "flaky"]
    exit_code = 1 if (failures or gate_failed or unstable) else 0
    # 一个栈都没跑成（工具链都没有）时不能返回 0：那会被当成「测试通过了」。
    # 但「选都没选中」是另一回事——只改配置时本来就没测试可跑，那是没得跑不是跑不成，
    # 报 2 会把门禁已过的事实盖掉，也会让 pre-commit 之类的调用方误判失败。
    nothing_ran = not any(r.get("status") != "skipped" for r in results.values())
    selected_any = any((plan.get(s) or {}).get("mode") != "none" for s in stacks)
    if nothing_ran and selected_any and not failures and not unstable and not gate_failed:
        exit_code = 2

    if args.json:
        print(json.dumps(_json_view(payload, exit_code), ensure_ascii=False, indent=2))
        return exit_code

    _print_human(payload, results, failures, gate, args, deploy)
    return exit_code


def _print_human(payload: dict, results: dict, failures: list[dict],
                 gate: dict | None, args, deploy: list[str] | None = None) -> None:
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
        print_gate(gate)

    print()
    skipped = [_NAMES[s] for s in select.STACKS
               if (results.get(s) or {}).get("status") == "skipped"]
    ran = [_NAMES[s] for s in select.STACKS
           if results.get(s) and results[s].get("status") != "skipped"]
    unstable = [s for s in select.STACKS if (results.get(s) or {}).get("status") == "flaky"]
    gate_failed = gate_failures(gate)
    if failures:
        new_count = sum(1 for f in failures if f["badge"] == "新增失败")
        extra = (f"{'、'.join(_GATE_LABELS.get(n, n) for n in gate_failed)}未通过。"
                 if gate_failed else "")
        print(f"结论：{len(failures)} 项失败（{new_count} 项新增）。{extra}")
    elif gate_failed:
        print(f"结论：测试通过，但 {'、'.join(_GATE_LABELS.get(n, n) for n in gate_failed)}未通过。")
    elif skipped and not ran:
        # 「没选中」和「跑不成」是两回事：前者本来就没得跑，后者是工具链缺失。
        selection = payload.get("selection") or {}
        selected_any = any((selection.get(stack) or {}).get("mode") != "none"
                           for stack in select.STACKS)
        if not selected_any:
            gate_note = "，门禁通过。" if gate else "。"
            print(f"结论：没有选中任何测试（改动不触及这三个栈的代码）{gate_note}")
        else:
            print(f"结论：什么都没跑成（{'、'.join(skipped)} 都不可用），不等于通过。")
    elif unstable:
        print(f"结论：{'、'.join(_NAMES[s] for s in unstable)} 疑似不稳定（首跑失败、复跑通过）。"
              "CI 不会重试，这里按失败算。")
    elif skipped:
        print(f"结论：{'、'.join(ran)} 通过；{'、'.join(skipped)} 没执行（不算通过）。")
    else:
        print("结论：全部通过。可以提交。")

    # 改了配置/部署时选不到测试，光说「全部通过」会让人以为验过了——把人交给 smoke。
    if deploy and not any((results.get(stack) or {}).get("status") != "skipped"
                          for stack in select.STACKS):
        print()
        print(f"  · 改了 {len(deploy)} 个配置/部署文件，devkit 选不到这部分的测试——"
              "部署后用下面这条验：")
        print("      python scripts/smoke.py --base-url <地址>")

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
        "deploy_touch": payload.get("deploy_touch") or [],
    }
