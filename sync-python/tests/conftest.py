"""测试用的本地桩服务，模拟来源站点与 Java 内部导入接口。

测试不依赖外网，也不依赖真实的 Java 后端；桩服务的行为可通过 state 控制，
用来验证重试、认证失败、幂等提交等路径。
"""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, urlparse

import pytest

# 三条同名的动画记录，用来验证"重名不得合并"（验收 D10）
# 字段按 2026-10-20 站主升级后的真实结构给出，覆盖三种情况：
#   476   完整字段（含封面、标签、无年份）
#   979   标签为空列表 -> 明确无标签，应映射为 [] 而非 None
#   10900 comic，来源未返回 cover_url/tags/year -> 应映射为 None
#   9999  空标题，应在校验阶段被拒绝
SAMPLE_ITEMS: list[dict[str, Any]] = [
    {
        "id": 476,
        "title": "街角魔族 2丁目",
        "type": "anime",
        "summary": "第一行\r\n第二行\r\n第三行",
        "rating": 7.8,
        "cover_url": "/media/full/cover_313852.jpg",
        "tags": ["搞笑", "百合", "日常"],
        "year": None,
        "bangumi_id": 313852,
    },
    {
        "id": 979,
        "title": "街角魔族",
        "type": "anime",
        "summary": "某日突然觉醒暗之力的女子高中生 吉田优子。",
        "rating": 7.5,
        "cover_url": "/media/full/cover_272510.jpg",
        "tags": [],
        "year": 2021,
        "bangumi_id": 272510,
    },
    {
        "id": 10900,
        "title": "街角魔族",
        "type": "comic",
        "summary": "　",  # 空白字符串，应被清洗为 None
        "rating": 8.5,
        # 来源未提供 cover_url / tags / year 三个字段
    },
    {
        "id": 9999,
        "title": "",  # 空标题，应在校验阶段被拒绝
        "type": "anime",
        "summary": "无标题记录",
        "rating": 5.0,
    },
]

# /api/tags 的实际形态是 {type, total, items:[{name, count}]}
SAMPLE_TAGS: list[dict[str, Any]] = [
    {"name": "TV", "count": 2974},
    {"name": "漫画改", "count": 1543},
    {"name": "剧场版", "count": 1476},
    {"name": "搞笑", "count": 964},
]


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args: Any) -> None:  # 静音，避免污染测试输出
        return

    def _send(self, status: int, payload: Any) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == "/api/contents":
            work_type = (query.get("type") or [""])[0]
            matched = [
                item
                for item in self.server.state["items"]
                if not work_type or item.get("type") == work_type
            ]
            # 不传 page/page_size 时保持老的全量行为
            raw_page = query.get("page")
            if raw_page is None:
                self._send(200, {"items": matched})
                return
            page = int(raw_page[0])
            page_size = int((query.get("page_size") or ["20"])[0])
            start = (page - 1) * page_size
            total_pages = max(1, (len(matched) + page_size - 1) // page_size)
            self.server.state["pages_requested"].append(page)
            self._send(
                200,
                {
                    "total": len(matched),
                    "page": page,
                    "page_size": page_size,
                    "total_pages": total_pages,
                    "items": matched[start : start + page_size],
                },
            )
            return
        if parsed.path == "/api/tags":
            tags = self.server.state.get("tags") or SAMPLE_TAGS
            limit = int((query.get("limit") or [str(len(tags))])[0])
            self._send(
                200,
                {
                    "type": (query.get("type") or [""])[0],
                    "total": len(tags),
                    "items": tags[:limit],
                },
            )
            return
        self._send(404, {"code": "NOT_FOUND", "message": self.path})

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path != "/internal/import/batches":
            self._send(404, {"code": "NOT_FOUND", "message": self.path})
            return

        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        payload = json.loads(raw or b"{}")
        state = self.server.state
        state["attempts"] += 1
        state["received"].append(payload)

        forced = state.get("status")
        if forced:
            self._send(forced, {"code": "FORCED", "message": "forced failure"})
            return
        if state.get("fail_times", 0) > 0:
            state["fail_times"] -= 1
            self._send(503, {"code": "INTERNAL_ERROR", "message": "temporary"})
            return

        items = payload.get("items") or []
        errors = []
        counts = {"inserted": 0, "updated": 0, "unchanged": 0, "rejected": 0}
        for item in items:
            if not (item.get("title") or "").strip():
                counts["rejected"] += 1
                errors.append(
                    {
                        "source_id": item.get("source_id"),
                        "result": "rejected",
                        "work_id": None,
                        "reason_code": "TITLE_REQUIRED",
                        "message": "title 为空",
                    }
                )
            else:
                counts["inserted"] += 1

        self._send(
            200,
            {
                "batch_id": payload.get("batch_id"),
                "counts": counts,
                "errors": errors,
                "started_at": payload.get("fetched_at"),
                "finished_at": payload.get("fetched_at"),
            },
        )


class _StubServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self) -> None:
        super().__init__(("127.0.0.1", 0), _Handler)
        self.state: dict[str, Any] = {
            "items": list(SAMPLE_ITEMS),
            "tags": list(SAMPLE_TAGS),
            "pages_requested": [],
            "attempts": 0,
            "received": [],
            "fail_times": 0,
            "status": None,
        }


class Stub:
    """包装桩服务，暴露 base_url 与状态控制。"""

    def __init__(self) -> None:
        self._server = _StubServer()
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()

    @property
    def base_url(self) -> str:
        host, port = self._server.server_address[:2]
        return f"http://{host}:{port}"

    @property
    def state(self) -> dict[str, Any]:
        return self._server.state

    def reset(self, **kwargs: Any) -> None:
        self.state.update(
            {
                "attempts": 0,
                "received": [],
                "fail_times": 0,
                "status": None,
                "pages_requested": [],
            }
        )
        self.state.update(kwargs)

    def stop(self) -> None:
        self._server.shutdown()
        self._server.server_close()
        self._thread.join(timeout=5)


@pytest.fixture()
def stub() -> Any:
    server = Stub()
    try:
        yield server
    finally:
        server.stop()
