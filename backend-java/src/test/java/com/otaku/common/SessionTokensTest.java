package com.otaku.common;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.HashSet;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class SessionTokensTest {

    @Test
    @DisplayName("令牌是 43 字符的 Base64URL，可安全放在 Authorization 头里")
    void tokenFormat() {
        String token = SessionTokens.newToken();

        assertThat(token).hasSize(43);
        assertThat(token).matches("[A-Za-z0-9_-]{43}");
    }

    @Test
    @DisplayName("每次生成都不同（32 字节随机）")
    void tokensAreUnique() {
        Set<String> seen = new HashSet<>();
        for (int i = 0; i < 2_000; i++) {
            assertThat(seen.add(SessionTokens.newToken())).isTrue();
        }
    }

    @Test
    @DisplayName("摘要稳定且为 64 位十六进制，库里只存它")
    void hashIsStableHex() {
        String token = "abc123";

        assertThat(SessionTokens.hash(token)).hasSize(64).matches("[0-9a-f]{64}");
        assertThat(SessionTokens.hash(token)).isEqualTo(SessionTokens.hash(token));
        assertThat(SessionTokens.hash("abc124")).isNotEqualTo(SessionTokens.hash(token));
    }
}
