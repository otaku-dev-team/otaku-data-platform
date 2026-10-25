"""只读接口快照对比：部署完跑一次，看「接口形状有没有悄悄变」。

跑的是真服务（本地 8088 或线上），只发 GET，不做写操作，不碰数据库。
记录两样东西：状态码 + 响应 JSON 的**键树**（递归取键名，数组只看首元素）。
下次再跑，跟上一份基线比：键消失 / 状态码漂移算回归，键新增算信息。

为什么要有这个：三个栈的测试都是拿假数据跑的，`docs/openapi.yaml` 只保证契约文件
自身合法（`scripts/check-contract.py` 明确不做三端字段比对）。真到线上，
「返回 200 但 `items` 里少了 `source`」这种事，只有真请求一次才看得见。

端点清单不写死：直接从 `docs/openapi.yaml` 取所有 GET 路径——契约就是清单，
加接口只改契约一处，这里自动跟上（写死的清单迟早会漏，acgn 那边漏过一次）。

带 `{id}` 的详情类接口不跳过：先用同前缀的列表接口取第一条真实 id 现场渲染。
取不到就单列「缺样本」，不算通过也不算失败。

用法::

    python scripts/smoke.py --base-url http://127.0.0.1:8088 --save   # 首次/更新基线
    python scripts/smoke.py --base-url https://api.example.com         # 部署后对比
    python scripts/smoke.py --list                                    # 只列端点
    python scripts/smoke.py --json                                    # 机器可读

退出码：0 无回归；1 有回归（键消失/状态码漂移）；2 无法执行。

历史（回答「从哪次开始坏」）
----------------------------
每次跑完自动往 `scripts/smoke-history/` 追加一份完整快照（保留最近 20 份，不入库），
有回归时除了报「不一致」，还会回溯历史指出这条回归**最早出现在哪一次**、
以及它之前**最近一次正常是哪一次**（带当时的 commit）。不需要翻批次列表。

不想留痕用 `--no-history`。历史只与同一份基线比较：`--save` 换了基线，
旧的快照自动失效（`baseline_id` 不同），不会把「你刚确认的改动」当成回归。

注意：基线与运行环境的鉴权状态有关。匿名跑出来的 401 基线，不能拿去比带令牌的 200。
需要鉴权时用 `--header "Authorization: Bearer xxx"`，并保持一致。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = ROOT / "docs" / "openapi.yaml"
BASELINE = ROOT / "scripts" / "smoke-baseline.json"
HISTORY_DIR = ROOT / "scripts" / "smoke-history"
HISTORY_KEEP = 20

DEFAULT_BASE = "http://127.0.0.1:8088"

# 样本 id 可能落在这些键里（后端返回的是驼峰，契约里也是）。
_ID_KEYS = ("id", "workId", "publicId", "batchId", "accountId")


# --------------------------------------------------------------------------
# 端点清单：从契约里取，不写死
# --------------------------------------------------------------------------


def load_get_paths(spec_path: Path) -> list[str]:
    try:
        import yaml
    except ImportError:
        raise SystemExit("需要 PyYAML：pip install pyyaml（CI 的 contract job 里已装）")
    spec = yaml.safe_load(spec_path.read_text(encoding="utf-8"))
    paths = spec.get("paths") or {}
    found = [path for path, item in paths.items() if isinstance(item, dict) and "get" in item]
    return sorted(found)


def _display(path: Path) -> str:
    """仓库内的路径打成相对路径，仓库外（临时基线）原样打。"""
    try:
        return path.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return str(path)


def _first_id(payload) -> object | None:
    """列表响应里取第一条记录的 id。兼容裸数组与 {items: [...]} 两种形状。"""
    rows = payload
    if isinstance(payload, dict):
        rows = payload.get("items") or payload.get("data") or payload.get("list")
    if not isinstance(rows, list) or not rows:
        return None
    head = rows[0]
    if isinstance(head, dict):
        for key in _ID_KEYS:
            if head.get(key) is not None:
                return head[key]
    return head if isinstance(head, (str, int)) else None


# --------------------------------------------------------------------------
# 请求与键树
# --------------------------------------------------------------------------


_LOOPBACK = {"127.0.0.1", "localhost", "::1"}

# 连回环地址时绕开系统代理：本机常见 HTTP_PROXY=127.0.0.1:xxxx，
# urllib 会老实把请求丢给代理，结果连自己的服务都是 502。
_OPENER = urllib.request.build_opener()


def _build_opener(base_url: str) -> None:
    global _OPENER
    host = (urllib.parse.urlparse(base_url).hostname or "").lower()
    if host in _LOOPBACK:
        _OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _request(url: str, headers: dict[str, str], timeout: float) -> tuple[int, object]:
    request = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with _OPENER.open(request, timeout=timeout) as response:
            raw = response.read()
            status = response.status
    except urllib.error.HTTPError as exc:  # 4xx/5xx 也是有效信号，不吞
        raw = exc.read()
        status = exc.code
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return 0, {"error": f"{type(exc).__name__}: {exc}"}

    try:
        return status, json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return status, None


def key_tree(payload, prefix: str = "", out: set[str] | None = None) -> set[str]:
    """把 JSON 摊平成键路径集合。

    dict → `a.b`；list → `a[]` 再加首元素的键（`a[].id`）。只看首元素，
    因为数组长度是数据量不是形状，逐元素比会天天报差异。
    """
    if out is None:
        out = set()
    if isinstance(payload, dict):
        for key, value in payload.items():
            path = f"{prefix}.{key}" if prefix else key
            out.add(path)
            key_tree(value, path, out)
    elif isinstance(payload, list):
        out.add(f"{prefix}[]" if prefix else "[]")
        if payload:
            key_tree(payload[0], f"{prefix}[]" if prefix else "[]", out)
    return out


def collect(base_url: str, headers: dict[str, str], timeout: float) -> dict:
    """跑一遍全部 GET 端点，返回 {label: {status, keys}}。"""
    paths = load_get_paths(SPEC)
    plain = [p for p in paths if "{" not in p]
    with_params = [p for p in paths if "{" in p]

    results: dict[str, dict] = {}
    payloads: dict[str, object] = {}

    for path in plain:
        status, payload = _request(base_url + path, headers, timeout)
        payloads[path] = payload
        results[f"GET {path}"] = {
            "status": status,
            "keys": sorted(key_tree(payload)) if payload is not None else [],
        }

    for path in with_params:
        prefix = path.split("{")[0].rstrip("/")
        sample = _first_id(payloads.get(prefix))
        if sample is None:
            results[f"GET {path}"] = {"status": None, "keys": [], "note": "缺样本（列表接口没取到 id）"}
            continue
        resolved = path.replace("{work_id}", str(sample)).replace("{batch_id}", str(sample))
        if "{" in resolved:  # 还有别的占位符，本脚本不猜
            results[f"GET {path}"] = {"status": None, "keys": [], "note": "占位符未覆盖"}
            continue
        status, payload = _request(base_url + resolved, headers, timeout)
        results[f"GET {path}"] = {
            "status": status,
            "keys": sorted(key_tree(payload)) if payload is not None else [],
            "sample": resolved,
        }
    return results


# --------------------------------------------------------------------------
# 对比
# --------------------------------------------------------------------------


def compare(baseline: dict, current: dict) -> dict:
    """基线 vs 本次。regression = 键消失或状态码漂移；addition 只做提示。"""
    changes: list[dict] = []

    for label, now in current.items():
        before = baseline.get(label)
        if before is None:
            changes.append({"label": label, "kind": "new", "detail": "基线里没有这个端点"})
            continue
        if now.get("status") is None or before.get("status") is None:
            continue
        if now["status"] != before["status"]:
            changes.append({
                "label": label, "kind": "regression",
                "detail": f"状态码 {before['status']} → {now['status']}",
            })
            continue
        lost = sorted(set(before.get("keys") or []) - set(now.get("keys") or []))
        gained = sorted(set(now.get("keys") or []) - set(before.get("keys") or []))
        if lost:
            changes.append({
                "label": label, "kind": "regression",
                "detail": "字段消失：" + ", ".join(lost[:6]) + (" …" if len(lost) > 6 else ""),
            })
        if gained:
            changes.append({
                "label": label, "kind": "addition",
                "detail": "字段新增：" + ", ".join(gained[:6]) + (" …" if len(gained) > 6 else ""),
            })

    for label in set(baseline) - set(current):
        changes.append({"label": label, "kind": "regression", "detail": "端点消失（契约里已没有它）"})

    regressions = [c for c in changes if c["kind"] == "regression"]
    return {"changes": changes, "regressions": regressions,
            "additions": [c for c in changes if c["kind"] == "addition"],
            "news": [c for c in changes if c["kind"] == "new"]}


# --------------------------------------------------------------------------
# 历史：存在哪、怎么回溯
# --------------------------------------------------------------------------


def _git_state() -> str:
    """当前工作区的 commit（带 dirty 标记），只用于把回归钉到某次提交上。

    诚实说明：这里记的是**本地仓库**的 HEAD，不一定等于线上部署的那一版。
    它的用途是缩小排查范围，不是证明因果——真要坐实得看部署记录。
    """
    try:
        sha = subprocess.run(
            ["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
        if not sha:
            return "unknown"
        dirty = subprocess.run(
            ["git", "-C", str(ROOT), "status", "--porcelain", "--untracked-files=no"],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    return sha + ("+dirty" if dirty else "")


def baseline_id(endpoints: dict) -> str:
    """基线指纹。历史快照只跟「同一份基线」比，换基线等于换了一把尺子。"""
    payload = json.dumps(endpoints, sort_keys=True, ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()[:12]


def record_history(base_url: str, endpoints: dict, base_id: str) -> Path:
    """追加一份快照，并按数量裁剪旧文件。"""
    HISTORY_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    path = HISTORY_DIR / f"{stamp}.json"
    path.write_text(
        json.dumps({
            "version": 1,
            "ran_at": datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
            "base_url": base_url,
            "commit": _git_state(),
            "baseline_id": base_id,
            "endpoints": endpoints,
        }, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    for stale in sorted(HISTORY_DIR.glob("*.json"))[:-HISTORY_KEEP]:
        stale.unlink(missing_ok=True)
    return path


def history_entries(base_id: str) -> list[dict]:
    """按时间读回与当前基线同源的历史快照（文件名即时间，sorted 即可）。"""
    if not HISTORY_DIR.exists():
        return []
    entries: list[dict] = []
    for path in sorted(HISTORY_DIR.glob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue  # 半截文件（跑到一半被打断）不该让整个回溯挂掉
        if data.get("baseline_id") != base_id:
            continue
        entries.append(data)
    return entries


def blame(regressions: list[dict], baseline: dict, entries: list[dict]) -> dict:
    """对每条回归找「最早出现的那次」和它之前「最近一次正常的那次」。

    做法是把每份历史快照也拿**同一份基线**比一遍，得到那一刻的回归标签集合；
    某标签第一次出现在集合里，就是它变坏的那次。比记录「上次跑的结论」稳，
    因为历史快照是完整数据，口径统一，不怕当年用的基线跟现在不一样。
    """
    if not regressions or not entries:
        return {}
    snapshots = [
        (entry, {c["label"] for c in compare(baseline, entry.get("endpoints") or {})["regressions"]})
        for entry in entries
    ]
    out: dict[str, dict] = {}
    for item in regressions:
        label = item["label"]
        out[label] = {"first_broken": None, "last_ok": None}
        for index, (entry, hits) in enumerate(snapshots):
            if label not in hits:
                continue
            out[label]["first_broken"] = entry
            for earlier, earlier_hits in reversed(snapshots[:index]):
                if label not in earlier_hits:
                    out[label]["last_ok"] = earlier
                    break
            break
    return out


def _stamp(entry: dict) -> str:
    """`2026-10-24T03:12:07` → `10-24 03:12:07`。带秒：连着跑两次时不能两行同字。"""
    at = entry.get("ran_at") or ""
    return f"{at[5:10]} {at[11:19]}".strip() or at


def _brief(entry: dict | None) -> dict | None:
    """回溯结果给机器看时只留定位信息，别把整份快照塞进 JSON。"""
    if not entry:
        return None
    return {"ran_at": entry.get("ran_at"), "commit": entry.get("commit"),
            "base_url": entry.get("base_url")}


# --------------------------------------------------------------------------
# 入口
# --------------------------------------------------------------------------


def _headers(raw: list[str]) -> dict[str, str]:
    headers = {"User-Agent": "otaku-smoke/1", "Accept": "application/json"}
    for item in raw:
        if ":" not in item:
            raise SystemExit(f"--header 格式应为 'Name: value'，收到：{item}")
        name, value = item.split(":", 1)
        headers[name.strip()] = value.strip()
    return headers


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="只读接口快照对比（部署后回归）")
    parser.add_argument("--base-url", default=DEFAULT_BASE, help=f"服务地址（默认 {DEFAULT_BASE}）")
    parser.add_argument("--save", action="store_true", help="把本次结果写成新基线")
    parser.add_argument("--baseline", default=str(BASELINE), help="基线文件路径")
    parser.add_argument("--header", action="append", default=[], help="附加请求头，可重复")
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--list", action="store_true", help="只列端点，不发请求")
    parser.add_argument("--json", action="store_true", help="机器可读输出")
    parser.add_argument("--no-history", action="store_true",
                        help="不写历史快照（默认每次跑都记一条，保留最近 20 条）")
    args = parser.parse_args(argv)

    if args.list:
        for path in load_get_paths(SPEC):
            print(f"GET {path}")
        return 0

    _build_opener(args.base_url)

    baseline_path = Path(args.baseline)
    current = collect(args.base_url, _headers(args.header), args.timeout)
    reachable = [
        label for label, item in current.items()
        if isinstance(item.get("status"), int) and item["status"] > 0
    ]
    if not reachable:
        note = (f"全部端点都连不上 {args.base_url}——服务没起，或地址/代理不对。\n"
                "  （本机若设了 HTTP_PROXY，记得 NO_PROXY=localhost,127.0.0.1）")
        if args.json:
            print(json.dumps({"base_url": args.base_url, "conclusion": "unreachable",
                              "error": note}, ensure_ascii=False, indent=2))
        else:
            print(note)
        return 2

    if args.save or not baseline_path.exists():
        baseline_path.write_text(
            json.dumps({"version": 1, "saved_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                        "endpoints": current}, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        recorded = None if args.no_history else record_history(
            args.base_url, current, baseline_id(current)
        )
        if args.json:
            print(json.dumps({"saved": str(baseline_path), "endpoints": current,
                              "history": str(recorded) if recorded else None},
                             ensure_ascii=False, indent=2))
        else:
            print(f"已写入基线：{_display(baseline_path)}（{len(current)} 个端点）")
            print("之后跑同一条命令（不带 --save）就会与它对比。")
        return 0

    baseline = json.loads(baseline_path.read_text(encoding="utf-8")).get("endpoints", {})
    base_id = baseline_id(baseline)
    entries = [] if args.no_history else history_entries(base_id)
    result = compare(baseline, current)
    blamed = blame(result["regressions"], baseline, entries)

    # 先回溯再落盘：本次不该出现在自己的「历史」里，否则「从哪次开始坏」永远指向今天。
    recorded = None
    if not args.no_history:
        recorded = record_history(args.base_url, current, base_id)

    if args.json:
        print(json.dumps({
            "base_url": args.base_url,
            "conclusion": "regression" if result["regressions"] else "clean",
            **result,
            "history": {
                "entries": len(entries),
                "recorded": str(recorded) if recorded else None,
                "blame": {
                    label: {
                        "first_broken": _brief(info["first_broken"]),
                        "last_ok": _brief(info["last_ok"]),
                    }
                    for label, info in blamed.items()
                },
            },
        }, ensure_ascii=False, indent=2))
    else:
        print(f"== {args.base_url} vs {_display(baseline_path)}：{len(current)} 个端点 ==")
        for item in result["regressions"]:
            print(f"  [回归] {item['label']} — {item['detail']}")
            info = blamed.get(item["label"]) or {}
            since, ok = info.get("first_broken"), info.get("last_ok")
            if since:
                line = f"         自 {_stamp(since)}（{since.get('commit', '?')}）起"
                if ok:
                    line += f"，上次正常：{_stamp(ok)}（{ok.get('commit', '?')}）"
                print(line)
            elif entries:
                print(f"         历史里首次出现（可回溯 {len(entries)} 条）")
        for item in result["additions"]:
            print(f"  [新增] {item['label']} — {item['detail']}")
        for item in result["news"]:
            print(f"  [新端点] {item['label']} — {item['detail']}（不堵门，确认后 --save 纳入基线）")
        if not result["changes"]:
            print("  接口形状与基线一致。")
        if recorded:
            print(f"  历史：可回溯 {len(entries)} 条，本次已记入 {_display(recorded)}")

    # `--json` 时 stdout 必须是纯 JSON，人看的结论走 stderr，否则管道一读就炸。
    out = sys.stderr if args.json else sys.stdout
    if result["regressions"]:
        print("结论：有回归（键消失或状态码漂移）。确认是预期改动就 --save 更新基线。", file=out)
        return 1
    print("结论：无回归。", file=out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
