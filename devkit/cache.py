"""结果缓存：同样的代码不必跑第二遍。

**保守优先**。缓存键用的是「该栈目录下所有被跟踪文件的哈希」，而不是依赖闭包——
闭包一旦漏掉一个文件，结果就是「跳过了一次本该失败的运行」，也就是假绿。
两者代价不对称：多失效一次只是多跑几十秒，误跳过会让坏代码过门。

想把缓存键放松成闭包哈希，得先有把握闭包是准的；在那之前不提供这个开关。
"""

from __future__ import annotations

import hashlib
import json
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STATE_DIR = ROOT / "devkit" / ".state"
CACHE_DIR = STATE_DIR / "cache"

# 这些东西进来只会让哈希变慢且毫无意义：构建产物、缓存目录、运行产物
_SKIP_DIRS = {
    "target", "build", ".dart_tool", "node_modules", "__pycache__",
    ".pytest_cache", "runs", ".gradle", ".idea", ".state",
}
_KEEP = 300


def _iter_files(base: Path):
    for path in sorted(base.rglob("*")):
        if not path.is_file():
            continue
        parts = set(path.parts)
        if parts & _SKIP_DIRS:
            continue
        yield path


def stack_fingerprint(base: Path) -> str:
    """整个栈目录的内容指纹（含源码、配置、依赖清单）。"""
    digest = hashlib.sha256()
    for path in _iter_files(base):
        try:
            digest.update(path.relative_to(ROOT).as_posix().encode("utf-8"))
            digest.update(b"\0")
            digest.update(path.read_bytes())
        except OSError:
            # 读不到的文件（被抓着/权限问题）直接让指纹失效，宁可重跑
            digest.update(b"<unreadable>")
        digest.update(b"\0")
    return digest.hexdigest()


def make_key(stack: str, command: list[str], files: list[str], base: Path) -> str:
    # 报告路径每次都是随机文件名，直接参与哈希会让缓存永不命中——把它抹成占位符。
    normalized = [
        "--junitxml=<report>" if token.startswith("--junitxml=") else token
        for token in command
    ]
    digest = hashlib.sha256()
    digest.update(stack.encode("utf-8"))
    digest.update("\n".join(normalized).encode("utf-8"))
    digest.update("\n".join(sorted(files)).encode("utf-8"))
    digest.update(stack_fingerprint(base).encode("utf-8"))
    return digest.hexdigest()[:32]


def load(key: str) -> dict | None:
    path = CACHE_DIR / f"{key}.json"
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def save(key: str, payload: dict) -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    payload = {**payload, "cached_at": time.strftime("%Y-%m-%dT%H:%M:%S")}
    (CACHE_DIR / f"{key}.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=1), encoding="utf-8")
    _prune()


def _prune() -> None:
    entries = sorted(CACHE_DIR.glob("*.json"), key=lambda p: p.stat().st_mtime)
    for stale in entries[:-_KEEP]:
        stale.unlink(missing_ok=True)


def clear() -> int:
    """清空缓存（`--clear-cache`）。"""
    if not CACHE_DIR.exists():
        return 0
    count = 0
    for path in CACHE_DIR.glob("*.json"):
        path.unlink(missing_ok=True)
        count += 1
    return count
