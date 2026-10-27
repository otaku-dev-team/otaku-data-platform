package com.otaku.console;

import java.time.LocalDateTime;

/**
 * site_admin + 所属站点的一行（联表结果）。
 *
 * <p>带上 {@code siteName} / {@code siteStatus} 是为了让鉴权只查一次库：
 * 后台每个请求都要判断「这个站主还有效吗、他的站点还开着吗」，
 * 分成两次查询就多一个「查到一半站点被停用」的窗口，也没必要。
 *
 * <p>{@code passwordHash} 可能为 NULL：{@code identity_source=site_oauth} 的站主
 * 走网站账号登录，平台侧不存任何凭据（这正是选方案 B 的理由）。
 */
public record SiteAdminRow(
        long id,
        String adminId,
        String siteKey,
        String siteName,
        String siteStatus,
        String username,
        String passwordHash,
        String displayName,
        String identitySource,
        String status,
        LocalDateTime lastLoginAt
) {

    public static final String STATUS_ACTIVE = "active";
    public static final String STATUS_DISABLED = "disabled";
    public static final String IDENTITY_PLATFORM = "platform";
    public static final String IDENTITY_SITE_OAUTH = "site_oauth";

    public boolean active() {
        return STATUS_ACTIVE.equals(status) && SiteRecord.STATUS_ACTIVE.equals(siteStatus);
    }
}
