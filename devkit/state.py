"""运行状态：上次结果、失败基线、历史。

失败基线是这一版最值钱的东西之一：没有它，「CI 挂了」只知道自己挂了，
不知道是不是自己弄挂的，三个人各自去查一遍。
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

from .cache import STATE_DIR, ROOT

LAST = STATE_DIR / "last.json"
RUNS = STATE_DIR / "runs"
_KEEP_RUNS = 50
SCHEMA = 2


def git_state() -> str:
    """本地 HEAD（带 dirty 标记）。只用于缩小排查范围，不等于线上部署的那一版。"""
    try:
        sha = subprocess.run(
            ["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
        dirty = subprocess.run(
            ["git", "-C", str(ROOT), "status", "--porcelain", "--untracked-files=no"],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    return sha + ("+dirty" if dirty else "") if sha else "unknown"


def load_last() -> dict:
    if not LAST.exists():
        return {}
    try:
        data = json.loads(LAST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if data.get("schema") == SCHEMA else {}


def previous_failures(per_stack: bool = True) -> dict[str, set[str]]:
    """上次失败过的用例 id。用来把「新增失败」和「上次也失败」分开。"""
    last = load_last()
    result: dict[str, set[str]] = {}
    for item in last.get("failures") or []:
        result.setdefault(item.get("stack", ""), set()).add(item.get("test_id", ""))
    return result


def save(payload: dict) -> Path:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    RUNS.mkdir(parents=True, exist_ok=True)
    payload = {**payload, "schema": SCHEMA}
    text = json.dumps(payload, ensure_ascii=False, indent=1)
    LAST.write_text(text, encoding="utf-8")
    stamp = (payload.get("ran_at") or "").replace(":", "").replace("-", "").replace("T", "-")
    path = RUNS / f"{stamp or 'run'}.json"
    path.write_text(text, encoding="utf-8")
    for stale in sorted(RUNS.glob("*.json"))[:-_KEEP_RUNS]:
        stale.unlink(missing_ok=True)
    return path


def history(limit: int = 20) -> list[dict]:
    if not RUNS.exists():
        return []
    runs = []
    for path in sorted(RUNS.glob("*.json"))[-limit:]:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        stacks = data.get("stacks") or {}
        runs.append({
            "ran_at": data.get("ran_at"),
            "commit": data.get("commit"),
            "elapsed": data.get("elapsed"),
            "failed": sum(int(s.get("failed") or 0) for s in stacks.values()),
            "total": sum(int(s.get("total") or 0) for s in stacks.values()),
            "cached": [name for name, s in stacks.items() if s.get("cached")],
        })
    return runs
