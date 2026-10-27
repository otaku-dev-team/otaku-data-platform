"""第二站（第三方来源）适配器集合。

本包只放「除现有 Otaku 站点与 Bangumi 档案之外的来源站适配器」。
Otaku 站点（`OtakuSiteSource`）与 Bangumi 档案（`BangumiArchiveSource`）
仍直接放在 `sync/` 下，沿用既有约定；新接的真实站统一进本包，便于归口。

所有适配器都复用 `sync.source.OtakuSiteSource` 的限流、退避重试与失败记账
（`_request` / `failed_pages`），不各自重写一套抓取骨架。
"""
