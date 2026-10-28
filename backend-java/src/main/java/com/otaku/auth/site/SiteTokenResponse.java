package com.otaku.auth.site;

/**
 * 站点 {@code POST /api/auth/token} 成功响应里平台需要的字段。
 *
 * <p>契约 §1：站点返回 {@code access_token}（Bearer，3600s）+
 * {@code user{external_user_id, nickname, avatar_url}}。
 *
 * <p>{@code nickname} / {@code avatarUrl} 仅在登录响应里透出给客户端展示一次，
 * **不落库、不再分发**（契约 §7）；映射锚只有 {@code externalUserId}。
 */
public record SiteTokenResponse(
        String accessToken,
        String externalUserId,
        String nickname,
        String avatarUrl
) {
}
