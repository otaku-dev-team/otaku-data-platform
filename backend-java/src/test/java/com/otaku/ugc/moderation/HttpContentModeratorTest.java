package com.otaku.ugc.moderation;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * 通用 HTTP 审核器：协议翻译 + 失败一律抛 {@link ModerationUnavailableException}。
 *
 * <p>用 JDK 自带的 {@code HttpServer} 打桩，不打真实服务商——这里要验的是
 * 「我们发出去什么、收到了怎么翻」，对方是不是真的审核器不重要。
 */
class HttpContentModeratorTest {

    private HttpServer server;
    private final AtomicReference<String> capturedBody = new AtomicReference<>();
    private final AtomicReference<String> capturedAuth = new AtomicReference<>();
    private volatile int responseStatus = 200;
    private volatile String responseBody = "{\"action\":\"pass\"}";
    private volatile long delayMs = 0;

    @BeforeEach
    void startStub() throws IOException {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/moderate", exchange -> {
            capturedBody.set(new String(exchange.getRequestBody().readAllBytes(),
                    StandardCharsets.UTF_8));
            capturedAuth.set(exchange.getRequestHeaders().getFirst("Authorization"));
            if (delayMs > 0) {
                try {
                    Thread.sleep(delayMs);
                } catch (InterruptedException ex) {
                    Thread.currentThread().interrupt();
                }
            }
            byte[] out = responseBody.getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().add("Content-Type", "application/json");
            exchange.sendResponseHeaders(responseStatus, out.length);
            exchange.getResponseBody().write(out);
            exchange.close();
        });
        server.start();
    }

    @AfterEach
    void stopStub() {
        server.stop(0);
    }

    @Test
    @DisplayName("pass → PASS")
    void pass() {
        assertThat(moderator().check(request()).verdict()).isEqualTo(ModerationVerdict.PASS);
    }

    @Test
    @DisplayName("reject 带理由 → REJECT，理由原样带出（截断交给 ModerationResult）")
    void reject() {
        responseBody = "{\"action\":\"reject\",\"reason\":\"含违规广告\"}";

        ModerationResult result = moderator().check(request());

        assertThat(result.verdict()).isEqualTo(ModerationVerdict.REJECT);
        assertThat(result.reason()).isEqualTo("含违规广告");
    }

    @Test
    @DisplayName("review → REVIEW；pending / block 两个常见写法顺手认掉")
    void reviewAliases() {
        responseBody = "{\"action\":\"review\"}";
        assertThat(moderator().check(request()).verdict()).isEqualTo(ModerationVerdict.REVIEW);

        responseBody = "{\"action\":\"PENDING\"}";
        assertThat(moderator().check(request()).verdict()).isEqualTo(ModerationVerdict.REVIEW);

        responseBody = "{\"action\":\"block\"}";
        assertThat(moderator().check(request()).verdict()).isEqualTo(ModerationVerdict.REJECT);
    }

    @Test
    @DisplayName("超长理由截断到 120 字：服务商的整段策略说明不该原样回显给用户")
    void longReasonTrimmed() {
        responseBody = "{\"action\":\"reject\",\"reason\":\"" + "违".repeat(300) + "\"}";

        assertThat(moderator().check(request()).reason()).hasSize(120);
    }

    @Test
    @DisplayName("请求体是四个字段的 JSON，token 走 Bearer 头")
    void requestShape() {
        moderator().check(new ModerationRequest("otaku", "comment", "你好"));

        assertThat(capturedBody.get())
                .contains("\"site_key\":\"otaku\"")
                .contains("\"scene\":\"comment\"")
                .contains("\"text\":\"你好\"");
        assertThat(capturedAuth.get()).isEqualTo("Bearer t0ken");
    }

    @Test
    @DisplayName("token 为空时不发 Authorization 头（不是发一个空的 Bearer）")
    void noTokenHeader() {
        moderator("http://127.0.0.1:" + port() + "/moderate", "", 1500)
                .check(request());

        assertThat(capturedAuth.get()).isNull();
    }

    @Test
    @DisplayName("非 2xx → 不可用（不当成「内容违规」）")
    void serverError() {
        responseStatus = 503;
        responseBody = "busy";

        assertThatThrownBy(() -> moderator().check(request()))
                .isInstanceOf(ModerationUnavailableException.class)
                .hasMessageContaining("HTTP 503");
    }

    @Test
    @DisplayName("响应不是 JSON → 不可用")
    void notJson() {
        responseBody = "<html>bad gateway</html>";

        assertThatThrownBy(() -> moderator().check(request()))
                .isInstanceOf(ModerationUnavailableException.class)
                .hasMessageContaining("不是 JSON");
    }

    @Test
    @DisplayName("action 认不出来 → 不可用（绝不猜成 pass，否则漏审没人发现）")
    void unknownAction() {
        responseBody = "{\"action\":\"suspicious\"}";

        assertThatThrownBy(() -> moderator().check(request()))
                .isInstanceOf(ModerationUnavailableException.class)
                .hasMessageContaining("可识别的 action");
    }

    @Test
    @DisplayName("超时 → 不可用；超时上限就是用户等待上限")
    void timeout() {
        delayMs = 800;
        HttpContentModerator slow = moderator("http://127.0.0.1:" + port() + "/moderate",
                "t0ken", 120);

        assertThatThrownBy(() -> slow.check(request()))
                .isInstanceOf(ModerationUnavailableException.class);
    }

    @Test
    @DisplayName("provider=http 但没配端点 → 启动即失败，别等到第一条评论")
    void blankEndpointFailsFast() {
        assertThatThrownBy(() -> new HttpContentModerator("  ", "", 1500, new ObjectMapper()))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("endpoint 为空");
    }

    @Test
    @DisplayName("超时时间必须为正数")
    void nonPositiveTimeoutFailsFast() {
        assertThatThrownBy(() -> new HttpContentModerator("http://127.0.0.1:1/x", "", 0,
                new ObjectMapper()))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("timeout-ms");
    }

    // --- 工具 ---

    private int port() {
        return server.getAddress().getPort();
    }

    private HttpContentModerator moderator() {
        return moderator("http://127.0.0.1:" + port() + "/moderate", "t0ken", 1500);
    }

    private HttpContentModerator moderator(String endpoint, String token, int timeoutMs) {
        return new HttpContentModerator(endpoint, token, timeoutMs, new ObjectMapper());
    }

    private static ModerationRequest request() {
        return new ModerationRequest("otaku", "comment", "你好");
    }
}
