"""配置。所有敏感值只从环境变量读取，不写入仓库。"""

from __future__ import annotations

import os
from dataclasses import dataclass, field

DEFAULT_SOURCE_BASE_URL = "http://154.8.194.198:8000"
DEFAULT_WORKS = ("anime",)
RATING_SCALE = "0-10"
SOURCE_NAME = "otaku_site"


@dataclass(frozen=True)
class SyncConfig:
    """同步作业配置。"""

    source_base_url: str = DEFAULT_SOURCE_BASE_URL
    java_base_url: str = "http://localhost:8080"
    internal_token: str | None = None
    work_types: tuple[str, ...] = DEFAULT_WORKS
    batch_size: int = 100
    timeout_seconds: float = 30.0
    max_attempts: int = 3
    backoff_seconds: float = 2.0
    output_dir: str = "runs"
    user_agent: str = "otaku-data-platform-sync/0.1.0"
    extra_headers: dict[str, str] = field(default_factory=dict)

    @classmethod
    def from_env(cls, **overrides: object) -> "SyncConfig":
        """读取环境变量。内部令牌缺失时保持为 None，由调用方决定是否拒绝运行。"""
        work_types_raw = os.getenv("OTAKU_WORK_TYPES")
        work_types = (
            tuple(t.strip() for t in work_types_raw.split(",") if t.strip())
            if work_types_raw
            else DEFAULT_WORKS
        )
        raw = {
            "source_base_url": os.getenv("OTAKU_SOURCE_BASE_URL", DEFAULT_SOURCE_BASE_URL),
            "java_base_url": os.getenv("OTAKU_JAVA_BASE_URL", "http://localhost:8080"),
            "internal_token": os.getenv("OTAKU_INTERNAL_TOKEN"),
            "work_types": work_types,
            "batch_size": int(os.getenv("OTAKU_BATCH_SIZE", "100")),
            "timeout_seconds": float(os.getenv("OTAKU_TIMEOUT_SECONDS", "30")),
            "max_attempts": int(os.getenv("OTAKU_MAX_ATTEMPTS", "3")),
            "backoff_seconds": float(os.getenv("OTAKU_BACKOFF_SECONDS", "2")),
            "output_dir": os.getenv("OTAKU_OUTPUT_DIR", "runs"),
        }
        raw.update({k: v for k, v in overrides.items() if v is not None})
        return cls(**raw)  # type: ignore[arg-type]

    @property
    def import_url(self) -> str:
        return f"{self.java_base_url.rstrip('/')}/internal/import/batches"

    def batch_url(self, batch_id: str) -> str:
        return f"{self.import_url}/{batch_id}"
