package com.otaku.cover;

import com.otaku.config.AppProperties;
import com.otaku.work.WorkRecord;
import com.otaku.work.WorkRepository;
import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.time.Duration;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 封面回源白名单的边界行为。
 *
 * <p>三条都是**安全方向**的约定，不是功能特性：
 * <ol>
 *   <li>白名单为空 → **全部拒绝**（早期是"不限制"，方向搞反了）；</li>
 *   <li>host:port 必须精确匹配，默认端口按 http=80 / https=443 归一；</li>
 *   <li>重定向**每跳都过白名单**——否则一次 302 就能把请求带到任意主机，白名单形同虚设。</li>
 * </ol>
 */
class CoverAllowlistTest {

    @TempDir
    Path cacheDir;

    private final List<HttpServer> servers = new ArrayList<>();

    @AfterEach
    void stopServers() {
        servers.forEach(server -> server.stop(0));
    }

    @Test
    @DisplayName("白名单为空：一次请求都不发出去（fail-closed），返回空")
    void emptyAllowlistDeniesWithoutAnyRequest() throws Exception {
        AtomicInteger hits = new AtomicInteger();
        HttpServer server = startServer(exchange -> {
            hits.incrementAndGet();
            exchange.sendResponseHeaders(200, -1);
            exchange.close();
        });
        CoverService service = new CoverService(
                repositoryReturning("W-1", coverUrl(server, "/cover.jpg")),
                properties(List.of()));

        assertThat(service.load("W-1")).isEmpty();
        assertThat(hits.get()).as("白名单为空时必须一个包都不发").isZero();
    }

    @Test
    @DisplayName("白名单为 null 时同样拒绝，不能因为没配置就放开")
    void nullAllowlistDenies() {
        CoverService service = new CoverService(mock(WorkRepository.class), properties(null));

        assertThat(service.isAllowed(URI.create("http://127.0.0.1:8080/cover.jpg"))).isFalse();
    }

    @Test
    @DisplayName("端口必须精确匹配：同主机不同端口不放行")
    void portMustMatch() {
        CoverService service = new CoverService(
                mock(WorkRepository.class), properties(List.of("example.com:8080")));

        assertThat(service.isAllowed(URI.create("http://example.com:8080/a.jpg"))).isTrue();
        assertThat(service.isAllowed(URI.create("http://example.com:8081/a.jpg"))).isFalse();
    }

    @Test
    @DisplayName("省略端口时按默认端口归一：https=443、http=80")
    void defaultPortsAreNormalized() {
        CoverService service = new CoverService(
                mock(WorkRepository.class), properties(List.of("example.com:443", "example.org:80")));

        assertThat(service.isAllowed(URI.create("https://example.com/a.jpg"))).isTrue();
        assertThat(service.isAllowed(URI.create("http://example.org/a.jpg"))).isTrue();
        assertThat(service.isAllowed(URI.create("http://example.com/a.jpg")))
                .as("http 默认 80，与配置的 443 不是同一个端口").isFalse();
    }

    @Test
    @DisplayName("主机名比较忽略大小写，配置里的空白会被忽略")
    void hostComparisonIsCaseInsensitiveAndTrimmed() {
        CoverService service = new CoverService(
                mock(WorkRepository.class), properties(List.of("  Example.COM:8080  ")));

        assertThat(service.isAllowed(URI.create("http://example.com:8080/a.jpg"))).isTrue();
    }

    @Test
    @DisplayName("重定向到白名单外的主机：请求不能发出去")
    void redirectOutsideAllowlistIsRejected() throws Exception {
        AtomicInteger targetHits = new AtomicInteger();
        HttpServer target = startServer(exchange -> {
            targetHits.incrementAndGet();
            byte[] bytes = "should-not-be-fetched".getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(200, bytes.length);
            exchange.getResponseBody().write(bytes);
            exchange.close();
        });

        String location = coverUrl(target, "/cover.jpg");
        HttpServer redirector = startServer(exchange -> {
            exchange.getResponseHeaders().add("Location", location);
            exchange.sendResponseHeaders(302, -1);
            exchange.close();
        });

        CoverService service = new CoverService(
                repositoryReturning("W-1", coverUrl(redirector, "/cover.jpg")),
                properties(List.of(hostKey(redirector))));

        assertThat(service.load("W-1")).isEmpty();
        assertThat(targetHits.get()).as("重定向目标不在白名单，绝不能真的发出去").isZero();
    }

    @Test
    @DisplayName("白名单内的重定向正常跟随：合法跳转不能被一起禁掉")
    void redirectInsideAllowlistIsFollowed() throws Exception {
        byte[] body = "fake-webp".getBytes(StandardCharsets.UTF_8);
        HttpServer server = startServer(exchange -> {
            if (exchange.getRequestURI().getPath().equals("/real.jpg")) {
                exchange.getResponseHeaders().add("Content-Type", "image/webp");
                exchange.sendResponseHeaders(200, body.length);
                exchange.getResponseBody().write(body);
            } else {
                exchange.getResponseHeaders().add("Location", "/real.jpg");
                exchange.sendResponseHeaders(302, -1);
            }
            exchange.close();
        });

        CoverService service = new CoverService(
                repositoryReturning("W-1", coverUrl(server, "/cover.jpg")),
                properties(List.of(hostKey(server))));

        Optional<CoverService.CoverPayload> payload = service.load("W-1");

        assertThat(payload).isPresent();
        assertThat(payload.get().body()).isEqualTo(body);
    }

    // ---------------------------------------------------------------- helpers

    private HttpServer startServer(com.sun.net.httpserver.HttpHandler handler) throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/", handler);
        server.start();
        servers.add(server);
        return server;
    }

    private static String coverUrl(HttpServer server, String path) {
        return "http://127.0.0.1:" + server.getAddress().getPort() + path;
    }

    private static String hostKey(HttpServer server) {
        return "127.0.0.1:" + server.getAddress().getPort();
    }

    private WorkRepository repositoryReturning(String workId, String coverUrl) {
        WorkRepository repository = mock(WorkRepository.class);
        when(repository.findByWorkId(workId)).thenReturn(Optional.of(work(workId, coverUrl)));
        return repository;
    }

    private AppProperties properties(List<String> allowedHosts) {
        AppProperties properties = new AppProperties();
        AppProperties.Cover cover = properties.getCover();
        cover.setCacheDir(cacheDir.toString());
        cover.setAllowedHosts(allowedHosts);
        cover.setRatePerSecond(100);
        cover.setMaxConcurrency(2);
        cover.setTimeout(Duration.ofSeconds(5));
        return properties;
    }

    private static WorkRecord work(String workId, String coverUrl) {
        LocalDateTime now = LocalDateTime.now();
        return new WorkRecord(1L, workId, "anime", "标题", null, null,
                coverUrl, null, null, null, null, null, null,
                "otaku_site", "1", null, now, now);
    }
}
