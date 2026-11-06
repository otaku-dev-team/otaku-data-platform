"""导入提交超时与抓取超时必须是两个值（#365 实测）。

## 为什么分开

`timeout_seconds`（默认 30）是给**抓单个页面 / 单个 subject** 的：30 秒没响应就是卡死了，
等更久只会让整批更晚失败。

但提交导入批次是另一回事：一批最多 500 条、每条一个事务。2026-11-06 实测（临时 MySQL 8.0.46）：
- 首次导入 500 条 **9,513 ms**；
- 同一批重复提交（全 unchanged）**1,778 ms**。

本机 9.5 秒，生产 2C2G + 同机 MySQL 慢 2–3 倍就是 20–30 秒，正好压在原来那个 30 秒上。
超时的后果是整批重跑一遍（后端不短路），白烧 CPU 与连接。

所以导入单独给 120 秒。**不要图省事把全局 `timeout_seconds` 调到 120**——那会让抓取卡死
也等两分钟。
"""

from __future__ import annotations

from sync.config import SyncConfig


def test_import_timeout_defaults_to_120_seconds():
    config = SyncConfig()
    assert config.import_timeout_seconds == 120.0


def test_fetch_timeout_stays_at_30_seconds():
    """抓取超时不能被导入需求连带放大。"""
    config = SyncConfig()
    assert config.timeout_seconds == 30.0


def test_import_timeout_can_be_overridden_by_env(monkeypatch):
    monkeypatch.setenv("OTAKU_IMPORT_TIMEOUT_SECONDS", "45")
    config = SyncConfig.from_env()
    assert config.import_timeout_seconds == 45.0


def test_fetch_timeout_env_is_independent(monkeypatch):
    """两个环境变量互不影响——设了抓取超时，导入超时仍是默认。"""
    monkeypatch.setenv("OTAKU_TIMEOUT_SECONDS", "5")
    monkeypatch.delenv("OTAKU_IMPORT_TIMEOUT_SECONDS", raising=False)
    config = SyncConfig.from_env()
    assert config.timeout_seconds == 5.0
    assert config.import_timeout_seconds == 120.0
