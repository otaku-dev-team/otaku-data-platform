package com.otaku.user;

import java.time.LocalDateTime;

/**
 * app_user 的一行。密码摘要不出现在任何 DTO 里。
 *
 * <p>{@code siteKey} 是站主后台（Issue #144）的隔离依据：站主只能看/管自己站点的账号。
 * 为 {@code null} 表示未归属任何站点（本迁移之前建的历史账号），
 * 这类账号**任何站主都看不到、也禁不了**——宁可漏管，不能让 A 站管到 B 站的人。
 *
 * <p>{@code status=disabled} 的含义严格限定为「不能登录客户端」：
 * 平台不回写网站账号状态（提案 §4.2），所以这里禁的是"客户端登录"这件事，
 * 而不是"这个人"。（{@code app_user} 本来就是平台侧账号，与网站账号是两回事。）
 */
public record UserRecord(
        Long id,
        String userId,
        String username,
        String passwordHash,
        String siteKey,
        String status,
        LocalDateTime statusChangedAt,
        LocalDateTime createdAt,
        LocalDateTime updatedAt
) {

    public static final String STATUS_ACTIVE = "active";
    public static final String STATUS_DISABLED = "disabled";

    public boolean active() {
        return !STATUS_DISABLED.equals(status);
    }
}
