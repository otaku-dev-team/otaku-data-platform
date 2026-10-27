package com.otaku.config;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;

import java.nio.charset.StandardCharsets;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.options;

/**
 * 公共读限流 + CORS 收窄（Issue #188 形态 A）。
 *
 * <p>为什么单开一个上下文：限流额度必须在测试里调小（每分钟 2 次/1 次），
 * 而其它集成测试共用 `it` profile（限流关闭）——这是**配置驱动**的行为，
 * 用独立 properties 才能同时验证"开着的时候确实拦"和"别的测试不被误伤"。
 *
 * <p>每个用例用不同的 {@code remoteAddr}：桶按 IP 分，共用一个 IP 会互相耗尽额度，
 * 让测试顺序变成隐藏依赖。
 */
@SpringBootTest(properties = {
        "app.rate-limit.enabled=true",
        "app.rate-limit.public-per-minute=8",
        "app.rate-limit.cover-per-minute=1",
        "app.cors.allowed-origins=http://site.example:8000"
})
@AutoConfigureMockMvc
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class RateLimitAndCorsIntegrationTest {

    @Autowired
    private MockMvc mvc;



    @Test
    @DisplayName("公共读超限返回 429 + Retry-After，且错误信封与其它接口一致")
    void publicReadIsRateLimited() throws Exception {
        String ip = "10.188.0.1";
        assertThat(status(get("/api/works").with(from(ip)))).isEqualTo(200);
        assertThat(status(get("/api/works").with(from(ip)))).isEqualTo(200);

        MvcResult limited = mvc.perform(get("/api/works").with(from(ip))).andReturn();
        assertThat(limited.getResponse().getStatus()).isEqualTo(429);
        assertThat(limited.getResponse().getHeader("Retry-After")).isEqualTo("60");
        assertThat(limited.getResponse().getContentAsString(StandardCharsets.UTF_8))
                .contains("RATE_LIMITED");
    }

    @Test
    @DisplayName("封面桶更严且与公共读分开计：耗完封面额度后列表仍可用")
    void coverBucketIsSeparateAndStricter() throws Exception {
        String ip = "10.188.0.2";
        // 封面额度 1：第一次放行（作品不存在 → 404，但仍算一次），第二次 429
        assertThat(status(get("/api/covers/W-notexist").with(from(ip)))).isEqualTo(404);
        assertThat(status(get("/api/covers/W-notexist").with(from(ip)))).isEqualTo(429);
        // 公共读额度未动
        assertThat(status(get("/api/works").with(from(ip)))).isEqualTo(200);
    }

    @Test
    @DisplayName("CORS 只放行配置的来源与本地调试；别站 Origin 预检被拒")
    void corsIsNarrowed() throws Exception {
        // 预检也是请求，会被限流；用不同 IP 隔离，别让 CORS 断言依赖限流额度
        MvcResult allowed = mvc.perform(options("/api/works")
                        .header("Origin", "http://site.example:8000")
                        .header("Access-Control-Request-Method", "GET")
                        .with(from("10.188.0.11")))
                .andReturn();
        assertThat(allowed.getResponse().getStatus()).isEqualTo(200);
        assertThat(allowed.getResponse().getHeader("Access-Control-Allow-Origin"))
                .isEqualTo("http://site.example:8000");

        MvcResult localhost = mvc.perform(options("/api/works")
                        .header("Origin", "http://localhost:5173")
                        .header("Access-Control-Request-Method", "GET")
                        .with(from("10.188.0.12")))
                .andReturn();
        assertThat(localhost.getResponse().getStatus()).as("本地调试端口默认放行").isEqualTo(200);

        MvcResult evil = mvc.perform(options("/api/works")
                        .header("Origin", "http://evil.example.com")
                        .header("Access-Control-Request-Method", "GET")
                        .with(from("10.188.0.13")))
                .andReturn();
        assertThat(evil.getResponse().getStatus()).isEqualTo(403);
        assertThat(evil.getResponse().getHeader("Access-Control-Allow-Origin")).isNull();

        // 简单请求（非预检）带别站 Origin：Spring 直接 403，而不是"返回数据但不给 ACAO"——
        // 后者仍会被同源策略挡住，但前者能省掉一次无意义的数据库查询。
        MvcResult simple = mvc.perform(get("/api/works").header("Origin", "http://evil.example.com")
                        .with(from("10.188.0.9")))
                .andReturn();
        assertThat(simple.getResponse().getStatus()).isEqualTo(403);
        assertThat(simple.getResponse().getHeader("Access-Control-Allow-Origin")).isNull();
    }

    private int status(MockHttpServletRequestBuilder request) throws Exception {
        return mvc.perform(request).andReturn().getResponse().getStatus();
    }

    /** 给请求换一个来源 IP（拦截器按 remoteAddr 分桶）。 */
    private static org.springframework.test.web.servlet.request.RequestPostProcessor from(String ip) {
        return request -> {
            request.setRemoteAddr(ip);
            return request;
        };
    }
}
