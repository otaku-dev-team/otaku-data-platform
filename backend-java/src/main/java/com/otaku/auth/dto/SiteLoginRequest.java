package com.otaku.auth.dto;

/**
 * 站点授权票据换平台会话的请求（契约 identity-linkup-contract.md §2，Issue #242）。
 *
 * <p>ticket 是站点 {@code /oauth/authorize} 回跳带来的一次性票据（120 秒有效），
 * 平台后端不落 ticket——它用完即废，落库反而制造了一条可重放的记录。
 */
public record SiteLoginRequest(String ticket) {
}
