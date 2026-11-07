package com.otaku.auth.dto;

/**
 * 当前用户信息，字段与 docs/stage2-account-collection-contract.md §4.2 对齐。
 *
 * <p>{@code displayName} 首期不做，固定返回 null，客户端回落到 username；
 * 例外是站点登录那一次会带上站点昵称，**仅供当次展示**（契约 §7，不落库、不再分发）。
 *
 * <p>{@code identitySource} 是**账号身份来源**（W1「登录页双入口」给后端的第 2 个输入）：
 * {@code null} = 平台账号（用户名密码建的），非空 = 由站点授权建立的账号（当前只有
 * {@code otaku_site}）。客户端据此决定账号菜单显不显示「身份来源」小字与
 * 「断开与网站的连接」——平台账号没有站点连接可断，不该看到那个入口。
 */
public record UserDto(String userId, String username, String displayName,
                      java.time.Instant createdAt, String identitySource) {
}
