package com.otaku.common;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Base64;
import java.util.HexFormat;

/**
 * 会话令牌的生成与摘要。
 *
 * 设计取舍：
 * - 令牌是 32 字节随机数，Base64URL 无填充（43 字符），不携带任何用户信息，客户端只当不透明串；
 * - 库里只存 SHA-256(token)，泄库也无法直接冒用；校验时对到来令牌做同样摘要再查；
 * - 不用 JWT：验收 C1/C9 要求一端退出不影响另一端、且要能看到会话列表，DB 会话最直接，
 *   JWT 想撤销还得再建黑名单。
 */
public final class SessionTokens {

    private static final SecureRandom RANDOM = new SecureRandom();
    private static final int TOKEN_BYTES = 32;

    private SessionTokens() {
    }

    public static String newToken() {
        byte[] bytes = new byte[TOKEN_BYTES];
        RANDOM.nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    public static String hash(String token) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            return HexFormat.of().formatHex(digest.digest(token.getBytes(StandardCharsets.UTF_8)));
        } catch (Exception ex) {
            throw new IllegalStateException("SHA-256 不可用", ex);
        }
    }
}
