"""提交批次到 Java 的内部导入接口。

对应 docs/openapi.yaml 的 `/internal/import/batches`。要点：
- 使用 `X-Internal-Token` 认证，令牌只从环境变量读取，不写入代码或仓库
- `batch_id` 是幂等键：同一批次重跑必须复用同一 batch_id，Java 侧不重复入库
- 只有网络错误、超时、5xx、429 才重试；4xx 一律不重试，直接失败并保留现场
- 请求失败不静默吞掉，交给上层记入批次报告
"""

from __future__ import annotations

from typing import Any, Sequence

import httpx
from tenacity import (
    Retrying,
    retry_if_exception_type,
    stop_after_attempt,
    wait_fixed,
)

from .config import SOURCE_NAME
from .models import BatchResult, WorkItem

RETRYABLE_STATUS = {429, 500, 502, 503, 504}


class ImportDeliveryError(RuntimeError):
    """批次未能送达或未被接受。可安全重跑：用同一 batch_id 重试。"""


class InternalImportError(RuntimeError):
    """接口拒绝了请求（认证失败、参数非法等），重试无意义。"""


class _Retryable(Exception):
    """内部使用的可重试信号。"""


class JavaImporter:
    """内部导入接口的客户端。"""

    def __init__(
        self,
        base_url: str,
        token: str | None = None,
        client: httpx.Client | None = None,
        timeout: float = 30.0,
        max_attempts: int = 3,
        backoff_seconds: float = 2.0,
        user_agent: str = "otaku-data-platform-sync/0.1.0",
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.max_attempts = max_attempts
        self.backoff_seconds = backoff_seconds
        self._client = client or httpx.Client(
            timeout=timeout, headers={"User-Agent": user_agent}
        )
        self._owns_client = client is None

    def close(self) -> None:
        if self._owns_client:
            self._client.close()

    @property
    def import_url(self) -> str:
        return f"{self.base_url}/internal/import/batches"

    def _headers(self) -> dict[str, str]:
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["X-Internal-Token"] = self.token
        return headers

    def _post(self, payload: dict[str, Any]) -> httpx.Response:
        try:
            resp = self._client.post(
                self.import_url, json=payload, headers=self._headers()
            )
        except (httpx.TimeoutException, httpx.TransportError) as exc:
            raise _Retryable(f"网络错误：{exc!r}") from exc
        if resp.status_code in RETRYABLE_STATUS:
            raise _Retryable(f"服务端返回 {resp.status_code}")
        return resp

    def submit_batch(
        self,
        batch_id: str,
        items: Sequence[WorkItem],
        fetched_at: str,
        source: str = SOURCE_NAME,
    ) -> BatchResult:
        """提交一个批次。成功返回 BatchResult，失败抛 ImportDeliveryError。

        `source` 必须显式传入并跟随配置（如 `bangumi`），不能写死为
        `SOURCE_NAME`——否则真推时批次级 source 会被错标成 otaku_site，
        与 dry-run 落盘的载荷不一致，也会让后端把不同来源的记录混在一起。
        """
        if not self.token:
            raise InternalImportError(
                "缺少内部导入令牌，请设置环境变量 OTAKU_INTERNAL_TOKEN"
            )
        payload = {
            "batch_id": batch_id,
            "source": source,
            "fetched_at": fetched_at,
            "items": [item.to_payload() for item in items],
        }
        retryer = Retrying(
            stop=stop_after_attempt(self.max_attempts),
            wait=wait_fixed(self.backoff_seconds),
            retry=retry_if_exception_type(_Retryable),
            reraise=True,
        )
        try:
            resp = retryer(self._post, payload)
        except _Retryable as exc:
            raise ImportDeliveryError(
                f"批次 {batch_id} 重试 {self.max_attempts} 次仍未送达：{exc}"
            ) from exc

        if resp.status_code in (401, 403):
            raise InternalImportError(
                f"导入接口拒绝认证（{resp.status_code}），请检查内部令牌"
            )
        if resp.status_code >= 400:
            raise InternalImportError(
                f"导入接口返回 {resp.status_code}：{resp.text[:200]}"
            )
        return BatchResult.from_payload(resp.json())

    def get_batch(self, batch_id: str) -> BatchResult:
        """查询已提交的批次结果，用于重跑核对。"""
        resp = self._client.get(f"{self.import_url}/{batch_id}", headers=self._headers())
        if resp.status_code == 404:
            raise InternalImportError(f"批次 {batch_id} 不存在")
        resp.raise_for_status()
        return BatchResult.from_payload(resp.json())
