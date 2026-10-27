"""第三方来源适配器集合。

本包只放「除现有 Otaku 站点与 Bangumi 档案之外的来源站适配器」。
Otaku 站点（`OtakuSiteSource`）与 Bangumi 档案（`BangumiArchiveSource`）
仍直接放在 `sync/` 下，沿用既有约定；新接的真实站统一进本包，便于归口。

抓取骨架（限流、退避重试、失败页记账）在 `sync/fetching.py`：
适配器各持一个 `FetchClient`，**组合而非继承首站适配器**。这样改首站的
作品/档期/资讯映射不会牵连第三方来源，接新站也只需「一个 client + 一份映射」。
"""
