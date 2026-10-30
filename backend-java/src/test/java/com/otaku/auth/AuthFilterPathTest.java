package com.otaku.auth;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 鉴权过滤器的路径覆盖：哪些请求必须过鉴权、哪些可以绕过。
 *
 * <p>为什么单独钉这一条：2026-10-30 上线的注销接口是 `DELETE /api/me`（精确路径），
 * 而过滤器只写了 `startsWith("/api/me/")`（带斜杠），于是 `/api/me` 被当成公开路径跳过，
 * `ATTRIBUTE_USER` 没注入，Controller 拿到 null → 生产直接 400。
 * 集成测试调的是 Service，绕过了 HTTP 层，所以没抓到。
 *
 * <p>这里只测判断函数本身，不启 Spring 上下文——路径匹配是纯逻辑，没必要为了它起一整套。
 */
class AuthFilterPathTest {

    private final AuthFilter filter = new AuthFilter(null, new ObjectMapper());

    private boolean filtered(String method, String path) {
        return !filter.shouldNotFilter(new MockHttpServletRequest(method, path));
    }

    @Test
    @DisplayName("精确路径 /api/me 必须过鉴权（注销接口就挂在这）")
    void exactMePathIsProtected() {
        assertThat(filtered("DELETE", "/api/me")).isTrue();
    }

    @Test
    @DisplayName("/api/me/ 下的子路径照常过鉴权")
    void meSubPathsAreProtected() {
        assertThat(filtered("GET", "/api/me/comments")).isTrue();
        assertThat(filtered("POST", "/api/me/comments")).isTrue();
        assertThat(filtered("GET", "/api/me/collections")).isTrue();
    }

    @Test
    @DisplayName("/api/auth/me 过鉴权；其它公开路径不过")
    void authMeAndPublicPaths() {
        assertThat(filtered("GET", "/api/auth/me")).isTrue();
        assertThat(filtered("GET", "/api/works")).isFalse();
        assertThat(filtered("GET", "/api/works/W-1/comments")).isFalse();
        assertThat(filtered("POST", "/api/auth/login")).isFalse();
    }
}
