"""本地看板：`python -m devkit serve --port 8787`。

只用标准库 `http.server`，不引框架、不引 npm、不构建——三个人用的东西不该需要一个
Node 工具链。将来要换成 FastAPI 或塞进 Electron，接口就三个（state / run / run 状态），
换宿主不影响数据形状。

安全边界：只绑 127.0.0.1，只接受预设动作，不接受任意命令与任意参数——
它会在你的机器上起子进程，不能做成通用的「远程执行」。
"""

from __future__ import annotations

import json
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from . import cache, select, state

UI_DIR = Path(__file__).resolve().parent / "ui"
ROOT = select.ROOT

# 动作 → 命令行参数。白名单，**不接受任意参数**。
ACTIONS = {
    "select": [],
    "gate": ["--gate"],
    "all": ["--all"],
    "rerun": ["--rerun-failed"],
}

_RUNS: dict[str, dict] = {}
_LOCK = threading.Lock()


def _start_run(action: str, stack: str | None) -> str:
    argv = list(ACTIONS.get(action) or [])
    if stack and stack in select.STACKS:
        argv += ["--stack", stack]
    run_id = uuid.uuid4().hex[:12]
    record = {"lines": [], "status": "running", "exit_code": None, "started": time.time()}
    with _LOCK:
        _RUNS[run_id] = record
        if len(_RUNS) > 20:   # 只留最近几次，别把内存当日志堆
            for stale in list(_RUNS)[:-20]:
                _RUNS.pop(stale, None)

    thread = threading.Thread(target=_exec, args=(run_id, argv), daemon=True)
    thread.start()
    return run_id


def _exec(run_id: str, argv: list[str]) -> None:
    record = _RUNS[run_id]
    cmd = [sys.executable, "-m", "devkit", *argv]
    try:
        proc = subprocess.Popen(
            cmd, cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, encoding="utf-8", errors="replace", bufsize=1,
        )
    except OSError as exc:
        record.update({"status": "error", "lines": [f"启动失败：{exc}"]})
        return
    for line in proc.stdout or []:
        record["lines"].append(line.rstrip("\n"))
    code = proc.wait()
    record["exit_code"] = code
    record["status"] = "done"


def _state_payload() -> dict:
    last = state.load_last()
    return {
        "last": last,
        "history": state.history(20),
        "inventory": select.inventory(),
        "cache_entries": len(list((cache.CACHE_DIR).glob("*.json")))
        if cache.CACHE_DIR.exists() else 0,
        "root": ROOT.as_posix(),
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "devkit-ui/2"

    def log_message(self, *args):   # 别把每个静态请求都打到终端
        pass

    def _send(self, status: int, body: bytes, ctype: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, payload: dict, status: int = 200) -> None:
        self._send(status, json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                   "application/json; charset=utf-8")

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path == "/api/state":
            return self._json(_state_payload())
        if path.startswith("/api/run/"):
            run_id = path.rsplit("/", 1)[-1]
            record = _RUNS.get(run_id)
            if not record:
                return self._json({"error": "没有这次运行"}, 404)
            return self._json(record)
        if path in ("/", "/index.html"):
            return self._static("index.html", "text/html; charset=utf-8")
        if path == "/app.js":
            return self._static("app.js", "application/javascript; charset=utf-8")
        if path == "/style.css":
            return self._static("style.css", "text/css; charset=utf-8")
        self._send(404, b"not found", "text/plain")

    def _static(self, name: str, ctype: str) -> None:
        target = UI_DIR / name
        if not target.is_file():
            return self._send(500, f"缺少界面文件 {name}".encode("utf-8"), "text/plain")
        self._send(200, target.read_bytes(), ctype)

    def do_POST(self) -> None:  # noqa: N802
        if self.path.split("?", 1)[0] != "/api/run":
            return self._json({"error": "not found"}, 404)
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            return self._json({"error": "请求体不是 JSON"}, 400)
        action = body.get("action") or "select"
        if action not in ACTIONS:
            return self._json({"error": f"不允许的动作：{action}"}, 400)
        running = [r for r in _RUNS.values() if r["status"] == "running"]
        if running:
            return self._json({"error": "已经有一次运行在跑"}, 409)
        return self._json({"run_id": _start_run(action, body.get("stack"))})


def main(argv: list[str] | None = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(prog="devkit serve", description="本地测试看板")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--open", action="store_true", help="启动后打印地址（不自动开浏览器）")
    args = parser.parse_args(argv)

    if not UI_DIR.is_dir():
        print(f"缺少界面目录：{UI_DIR}")
        return 2

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"devkit 看板：http://127.0.0.1:{args.port}")
    print("  只绑本机回环；Ctrl+C 结束。")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止。")
    finally:
        server.server_close()
    return 0
