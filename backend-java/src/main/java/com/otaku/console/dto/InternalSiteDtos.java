package com.otaku.console.dto;

import java.util.List;

/**
 * 平台侧开户用的内部请求体（{@code /internal/sites}、{@code /internal/site-admins}）。
 *
 * <p>它们**不是**站主后台的接口：站主走不到这两个路径（{@code InternalTokenFilter} 拦 /internal/**，
 * 令牌只在平台侧），后台页面里也没有任何调用点。
 * 站点接入与配置属于底座核心能力（提案 §2.2），开放给站主则服务价值归零。
 */
public final class InternalSiteDtos {

    private InternalSiteDtos() {
    }

    /**
     * 建站。<code>sources</code> 是本站的数据来源标识（与 work.source 同值），
     * 至少一项——空来源的站点在后台什么都不显示，且允许多站点共用一个 source 会直接破坏隔离。
     */
    public record SiteCreateRequest(String siteKey, String displayName, List<String> sources) {
    }

    /** 开设站主（加进站主名单，提案 §4.1）。 */
    public record SiteAdminCreateRequest(String siteKey, String username, String password, String displayName) {
    }

    /**
     * 停用 / 启用整个站点的结果。
     *
     * <p>{@code revoked_admin_sessions} 是该站**所有站主**被撤销的后台会话数：
     * 改状态只挡住下一次登录，已在后台里的浏览器要当场掉线（与用户禁用同一逻辑）。
     */
    public record SiteStatusChange(String siteKey, String status, int revokedAdminSessions, String note) {
    }

    /** 停用 / 启用单个站主的结果。解禁不会恢复旧会话，站主要重新登录。 */
    public record SiteAdminStatusChange(String adminId, String siteKey, String username,
                                        String status, int revokedSessions, String note) {
    }
}
