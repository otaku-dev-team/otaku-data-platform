package com.otaku.auth.site;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.config.AppProperties;
import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.web.client.RestClient;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * 站点令牌交换的**真 HTTP** 行为：请求形态、错误分档、超时。
 *
 * <p>用 JDK 自带 {@link HttpServer} 起一个假站点，不引 WireMock——
 * 这里要验的只有三件事实：表单字段精确、4xx 与 5xx 分档、超时归 UNAVAILABLE。
 * 契约 §1.1 的字段名（无 grant_type）与 §7 的错误归一都在这里被钉住。
 */
class HttpSiteAuthClientTest {

    private HttpServer server;
    private final ObjectMapper objectMapper = new ObjectMapper();
    private final AppProperties properties = new AppProperties();
    private final Map<String, String> lastForm = new ConcurrentHashMap<>();
    private final AtomicInteger hits = new AtomicInteger();

    /** 每个用例自定义的响应；默认 200 + 合法体。 */
    private volatile int status = 200;
    private volatile String responseBody = """
            {"access_token":"at-1","user":{"external_user_id":"42","nickname":"甲","avatar_url":"https://i/x.png"}}
            """;
    private volatile long delayMillis = 0;

    @BeforeEach
    void startServer() throws IOException {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/api/auth/token", exchange -> {
            hits.incrementAndGet();
            String raw = new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
            lastForm.clear();
            for (String pair : raw.split("&")) {
                String[] kv = pair.split("=", 2);
                if (kv.length == 2) {
                    lastForm.put(kv[0], java.net.URLDecoder.decode(kv[1], StandardCharsets.UTF_8));
                }
            }
            try {
                Thread.sleep(delayMillis);
            } catch (InterruptedException ignored) {
                Thread.currentThread().interrupt();
            }
            byte[] bytes = responseBody.getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().add("Content-Type", "application/json");
            exchange.sendResponseHeaders(status, bytes.length);
            try (OutputStream out = exchange.getResponseBody()) {
                out.write(bytes);
            }
        });
        server.start();

        properties.getSiteOauth().setBaseUrl("http://127.0.0.1:" + server.getAddress().getPort());
        properties.getSiteOauth().setClientId("otaku-app-client");
        properties.getSiteOauth().setClientSecret("s3cret");
        properties.getSiteOauth().setTimeout(Duration.ofSeconds(2));
    }

    @AfterEach
    void stopServer() {
        server.stop(0);
    }

    private HttpSiteAuthClient client() {
        return new HttpSiteAuthClient(RestClient.builder(), properties, objectMapper);
    }

    @Test
    @DisplayName("成功：表单字段精确为 client_id/client_secret/ticket（无 grant_type），解析出映射锚")
    void sendsExactFormAndParsesResponse() {
        SiteTokenResponse response = client().exchange("ticket-abc");

        assertThat(response.accessToken()).isEqualTo("at-1");
        assertThat(response.externalUserId()).isEqualTo("42");
        assertThat(response.nickname()).isEqualTo("甲");
        assertThat(lastForm).containsOnlyKeys("client_id", "client_secret", "ticket");
        assertThat(lastForm.get("client_id")).isEqualTo("otaku-app-client");
        assertThat(lastForm.get("ticket")).isEqualTo("ticket-abc");
    }

    @Test
    @DisplayName("站点 4xx（票据/凭据被拒，实测 401 invalid_client）：AUTH_FAILED，detail 只留给日志")
    void clientErrorIsAuthFailed() {
        status = 400;
        responseBody = "{\"detail\":\"invalid_client\"}";

        assertThatThrownBy(() -> client().exchange("bad"))
                .isInstanceOf(SiteAuthException.class)
                .satisfies(ex -> {
                    SiteAuthException site = (SiteAuthException) ex;
                    assertThat(site.failure()).isEqualTo(SiteAuthFailure.AUTH_FAILED);
                    assertThat(site.upstreamDetail()).isEqualTo("invalid_client");
                });
    }

    @Test
    @DisplayName("站点 5xx：UNAVAILABLE（重走授权解决不了，平台侧要说 503）")
    void serverErrorIsUnavailable() {
        status = 500;
        responseBody = "{\"detail\":\"boom\"}";

        assertThatThrownBy(() -> client().exchange("t"))
                .isInstanceOf(SiteAuthException.class)
                .satisfies(ex -> assertThat(((SiteAuthException) ex).failure())
                        .isEqualTo(SiteAuthFailure.UNAVAILABLE));
    }

    @Test
    @DisplayName("响应缺 external_user_id：按 UNAVAILABLE 处理，不把半截身份当成功")
    void responseWithoutAnchorIsUnavailable() {
        responseBody = "{\"access_token\":\"at-1\",\"user\":{}}";

        assertThatThrownBy(() -> client().exchange("t"))
                .isInstanceOf(SiteAuthException.class)
                .satisfies(ex -> assertThat(((SiteAuthException) ex).failure())
                        .isEqualTo(SiteAuthFailure.UNAVAILABLE));
    }

    @Test
    @DisplayName("超时：UNAVAILABLE，而不是把线程一直挂着")
    void timeoutIsUnavailable() {
        properties.getSiteOauth().setTimeout(Duration.ofMillis(200));
        delayMillis = 800;

        assertThatThrownBy(() -> client().exchange("t"))
                .isInstanceOf(SiteAuthException.class)
                .satisfies(ex -> assertThat(((SiteAuthException) ex).failure())
                        .isEqualTo(SiteAuthFailure.UNAVAILABLE));
    }

    @Test
    @DisplayName("未配置 secret：根本不发请求就 503（fail-closed，secret 不会以空串出站）")
    void unconfiguredDoesNotCallSite() {
        properties.getSiteOauth().setClientSecret("");

        assertThatThrownBy(() -> client().exchange("t"))
                .isInstanceOf(SiteAuthException.class)
                .satisfies(ex -> assertThat(((SiteAuthException) ex).failure())
                        .isEqualTo(SiteAuthFailure.UNAVAILABLE));
        assertThat(hits.get()).isZero();
    }
}
