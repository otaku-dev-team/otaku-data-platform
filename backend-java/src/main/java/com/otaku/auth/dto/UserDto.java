package com.otaku.auth.dto;

/**
 * 当前用户信息，字段与 docs/stage2-account-collection-contract.md §4.2 对齐。
 * display_name 首期不做，固定返回 null，客户端回落到 username。
 */
public record UserDto(String userId, String username, String displayName, java.time.Instant createdAt) {
}
