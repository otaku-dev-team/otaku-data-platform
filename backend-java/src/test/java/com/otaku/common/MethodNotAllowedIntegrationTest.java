package com.otaku.common;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;

import java.nio.charset.StandardCharsets;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/**
 * 不支持的方法 → 405（Issue #345）。
 *
 * <p>这条修复（#345 / {@code a923537}）上线时**没有测试**——zm 当时本机没有 Java 栈，
 * 靠 CI 编译验证，而 CI 只编译不跑行为。于是「405 不退回 500」这件事没有任何回归防护：
 * 谁把 {@link GlobalExceptionHandler} 的 handler 顺序/返回值改错，或新增一个
 * {@code @ExceptionHandler(Exception.class)} 更早的兜底，都不会有人发现。
 *
 * <p>断言的是**对外可观察的三件事**，不是实现细节：
 * <ol>
 *   <li>状态码 405，不是 500——调用方据此知道「重试没用」；</li>
 *   <li>信封与其它接口一致（{@code error.code = METHOD_NOT_ALLOWED}），
 *       客户端不需要为这一类错误另写分支；</li>
 *   <li>与 404（路径不存在）分得开——两者都是「客户端用错」，但修法不同。</li>
 * </ol>
 *
 * <p>为什么打 {@code /api/works} 而不是 issue 里的 {@code GET /api/me}：
 * {@code /api/me} 先被 {@code AuthFilter} 拦成 401，根本走不到方法匹配，
 * 用它测不到这个 handler。{@code /api/works} 是公共读，无需令牌。
 */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class MethodNotAllowedIntegrationTest {

    @Autowired
    private MockMvc mvc;

    @Test
    @DisplayName("不支持的方法返回 405 + 标准错误信封，不落到 500")
    void unsupportedMethodReturns405() throws Exception {
        var response = mvc.perform(post("/api/works"))
                .andReturn()
                .getResponse();

        assertThat(response.getStatus()).isEqualTo(405);
        assertThat(response.getContentType()).startsWith(MediaType.APPLICATION_JSON_VALUE);

        String body = response.getContentAsString(StandardCharsets.UTF_8);
        assertThat(body).contains("\"code\":\"METHOD_NOT_ALLOWED\"");
        // 落到兜底时会带 "INTERNAL"——这正是 #345 的症状，留作显式反例。
        assertThat(body).doesNotContain("INTERNAL");
        assertThat(body).doesNotContain("Exception");
        // RFC 9110 要求 405 带 Allow：只给状态码不给可用方法，客户端还得猜。
        assertThat(response.getHeader("Allow")).contains("GET");
    }

    @Test
    @DisplayName("路径不存在仍是 404，不与 405 混为一谈")
    void missingResourceStays404() throws Exception {
        var response = mvc.perform(get("/api/no-such-endpoint"))
                .andReturn()
                .getResponse();

        assertThat(response.getStatus()).isEqualTo(404);
        assertThat(response.getContentAsString(StandardCharsets.UTF_8))
                .contains("\"code\":\"WORK_NOT_FOUND\"");
    }

    @Test
    @DisplayName("Content-Type 不支持返回 415，不落到 500")
    void unsupportedMediaTypeReturns415() throws Exception {
        // 选一个确实消费 JSON 的写接口；405 与 415 的判定不冲突（方法是对的）。
        var response = mvc.perform(post("/api/auth/site-login")
                        .contentType(MediaType.TEXT_PLAIN)
                        .content("not json"))
                .andReturn()
                .getResponse();

        assertThat(response.getStatus()).isEqualTo(415);
        String body = response.getContentAsString(StandardCharsets.UTF_8);
        assertThat(body).contains("\"code\":\"UNSUPPORTED_MEDIA_TYPE\"");
        assertThat(body).doesNotContain("INTERNAL");
    }
}
