"""配置。所有敏感值只从环境变量读取，不写入仓库。"""

from __future__ import annotations

import os
from dataclasses import dataclass, field

DEFAULT_SOURCE_BASE_URL = "http://154.8.194.198:8000"
# VNDB kana API 根。**单独一份，不复用 source_base_url**——那个默认值指向
# 首站 Otaku，若 VNDB 分支沿用它，请求会打到首站而不是 VNDB。
# 契约第 4.6 节允许 source 取值自由（不设白名单），加 vndb 不改接口②③④。
DEFAULT_VNDB_BASE_URL = "https://api.vndb.org/kana"
# 来源站四类合计约 1.8 万条（动画 10917 / 漫画 2428 / 游戏 2464 / 轻小说 2109）。
# 默认全量同步四类：只同步 anime 是第一阶段联调用的临时设定，
# 留在默认值里会让"客户端内容只有几百条"看起来像是数据不够，实际是没同步。
DEFAULT_WORKS = ("anime", "comic", "game", "novel")
RATING_SCALE = "0-10"

# 来源标识。契约第 4.6 节：新增一个网站 = 加一份适配器配置 + 一个 source 取值。
#   otaku_site: 现有 Otaku 站点 JSON API（在线拉取）
#   bangumi   : Bangumi 官方数据集档案（本地 jsonlines 快照，见 docs 说明）
#   vndb      : VNDB kana API（在线拉取，视觉小说，W4 第二站）
# 三者 id 体系不同（站点 content_id vs Bangumi subject_id vs VNDB v17），
# 不能共用同一个 source，否则 (source, source_id) 唯一键会把几套 id 混在一起。
SOURCE_NAME = "otaku_site"
SOURCE_BANGUMI = "bangumi"
SOURCE_VNDB = "vndb"
VALID_SOURCES = (SOURCE_NAME, SOURCE_BANGUMI, SOURCE_VNDB)

# 来源方给出的限流口径（2026-10-20 站主答复，见 docs/旧站能力复用清单）：
# 单次全量走分页 page_size=200；并发不超过 2；控制在 1-2 req/s；每天不超过 5 万请求。
# 接口自身的 page_size 硬上限是 500（超过返回 422），但 200 是站主要求的用法，不要因为
# 能传 500 就传 500。本作业为串行拉取（并发 1），只需保证请求间隔落在 1-2 req/s 区间。
DEFAULT_PAGE_SIZE = 200
DEFAULT_REQUEST_INTERVAL_SECONDS = 0.6  # 约 1.67 req/s
DEFAULT_MAX_PAGES = 1000  # 安全阀，防止接口异常时无限翻页


@dataclass(frozen=True)
class SyncConfig:
    """同步作业配置。"""

    source_base_url: str = DEFAULT_SOURCE_BASE_URL
    # VNDB 单独一份地址。与 source_base_url 分开是因为两者指向不同的站：
    # source_base_url 默认是首站 Otaku，VNDB 的是 kana API，混用会打错站。
    vndb_base_url: str = DEFAULT_VNDB_BASE_URL
    java_base_url: str = "http://localhost:8080"
    internal_token: str | None = None
    work_types: tuple[str, ...] = DEFAULT_WORKS
    batch_size: int = 100
    source: str = SOURCE_NAME
    archive_path: str | None = None
    sample_method: str = "head"  # head=按档案顺序取前 N 条；uniform=蓄水池随机抽样
    source_page_size: int = DEFAULT_PAGE_SIZE
    request_interval_seconds: float = DEFAULT_REQUEST_INTERVAL_SECONDS
    max_pages: int = DEFAULT_MAX_PAGES
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
            "vndb_base_url": os.getenv("OTAKU_VNDB_BASE_URL", DEFAULT_VNDB_BASE_URL),
            "java_base_url": os.getenv("OTAKU_JAVA_BASE_URL", "http://localhost:8080"),
            "internal_token": os.getenv("OTAKU_INTERNAL_TOKEN"),
            "work_types": work_types,
            "batch_size": int(os.getenv("OTAKU_BATCH_SIZE", "100")),
            "source": os.getenv("OTAKU_SOURCE", SOURCE_NAME),
            "archive_path": os.getenv("OTAKU_ARCHIVE_PATH"),
            "sample_method": os.getenv("OTAKU_SAMPLE_METHOD", "head"),
            "source_page_size": int(os.getenv("OTAKU_SOURCE_PAGE_SIZE", str(DEFAULT_PAGE_SIZE))),
            "request_interval_seconds": float(
                os.getenv("OTAKU_REQUEST_INTERVAL_SECONDS", str(DEFAULT_REQUEST_INTERVAL_SECONDS))
            ),
            "max_pages": int(os.getenv("OTAKU_MAX_PAGES", str(DEFAULT_MAX_PAGES))),
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
