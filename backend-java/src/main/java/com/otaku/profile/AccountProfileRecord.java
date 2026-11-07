package com.otaku.profile;

import java.time.LocalDateTime;

/**
 * app_user 里与资料相关的列（#378）。
 *
 * <p>不复用 {@link com.otaku.user.UserRecord}：那个记录是登录身份，字段被
 * auth / session / console 多处构造；资料只在这一个模块读写，单独一个读模型
 * 可以避免为一个功能改八处测试构造器。
 */
public record AccountProfileRecord(
        long id,
        String userId,
        String username,
        String displayName,
        String bio,
        String avatarKey,
        LocalDateTime createdAt
) {
}
