package com.otaku.auth.dto;

import java.time.Instant;

/** 当前用户信息。不含口令摘要，也不含 app_user 自增 id。 */
public record UserDto(String userId, String username, Instant createdAt) {
}
