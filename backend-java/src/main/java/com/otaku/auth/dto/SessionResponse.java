package com.otaku.auth.dto;

import java.time.Instant;

/**
 * 登录/注册成功后的返回。
 * token 只在这里出现一次，之后客户端自己保存；服务端只留摘要。
 */
public record SessionResponse(String token, Instant expiresAt, UserDto user) {
}
