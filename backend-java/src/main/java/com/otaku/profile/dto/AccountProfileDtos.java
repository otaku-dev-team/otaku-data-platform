package com.otaku.profile.dto;

import java.time.Instant;

/**
 * 账号资料（#378）。
 *
 * <p>为什么单独一个 `AccountProfile` 而不是把字段塞进 `User`：
 * `User` 是**登录身份**（`/api/auth/me`、`/api/auth/site-login` 都返回它），
 * 而资料是可编辑的账号属性，还会带 bio/avatar 这类与鉴权无关的字段。
 * 混在一起会让每次登录响应都多背三个字段，也会把「站点昵称（仅当次展示）」
 * 与「平台自设昵称（落库）」两种语义塞进同一个 `display_name`。
 */
public final class AccountProfileDtos {

    private AccountProfileDtos() {
    }

    public record AccountProfile(
            String userId,
            String username,
            String displayName,
            String bio,
            String avatarUrl,
            Instant createdAt
    ) {
    }

    /** 两个字段都可空：空串由服务端归一为 null（不是存一个空字符串）。 */
    public record UpdateProfileRequest(
            String displayName,
            String bio
    ) {
    }

    public record AvatarUpload(
            String avatarUrl
    ) {
    }
}
