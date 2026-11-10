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
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.time.Duration;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.stream.IntStream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 回源闸门的**分档**行为。
 *
 * <p>背景（2026-11-11 生产实测）：一屏 10 张未缓存封面，最后一张 21.6 秒才出来，
 * 而同一批地址直连上游 6 路并发只要 5.1 秒——瓶颈在「所有主机共用 2 并发 / 2 req/s」。
 * 这档限流原本是**对来源站**的礼貌约定，不该连带第三方图床一起压。
 *
 * <p>这两个用例把边界钉死：
 * <ul>
 *   <li>名单里的主机能用上快速档（并发真的上去了）；</li>
 *   <li>名单外的主机仍然只有 2 并发——放宽不能变成"全部放宽"。</li>
 * </ul>
 */
class CoverHostLaneTest {

    @TempDir
    Path cacheDir;

    private HttpServer server;

    /** 服务端同时在处理的请求数，以及观察到的峰值。 */
    private final AtomicInteger active = new AtomicInteger();
    private final AtomicInteger maxActive = new AtomicInteger();

    @AfterEach
    void stopServer() {
        if (server != null) {
            server.stop(0);
        }
    }

    @Test
    @DisplayName("快速档主机：6 张封面并发回源，实际并发明显超过默认档的 2")
    void fastLaneRaisesConcurrency() throws Exception {
        startServer(250);
        CoverService service = service(List.of(hostPort()), 6);

        int peak = peakConcurrencyOfLoads(service, 6);

        assertThat(peak)
                .as("快速档给了 6 个许可；若还是 2，说明分档没生效")
                .isGreaterThanOrEqualTo(3);
    }

    @Test
    @DisplayName("名单外的主机：仍然是 2 并发，来源站的礼貌约定没被顺手放宽")
    void defaultLaneStaysPolite() throws Exception {
        startServer(250);
        CoverService service = service(List.of(), 2);

        int peak = peakConcurrencyOfLoads(service, 6);

        assertThat(peak)
                .as("默认档 2 个许可：放宽只能对名单内的主机生效")
                .isLessThanOrEqualTo(2);
    }

    @Test
    @DisplayName("host:port 归一：名单里写大写、请求是小写地址也能命中快速档")
    void fastHostMatchIgnoresCase() throws Exception {
        startServer(250);
        CoverService service = service(List.of(hostPort().toUpperCase()), 6);

        int peak = peakConcurrencyOfLoads(service, 6);

        assertThat(peak).isGreaterThanOrEqualTo(3);
    }

    /** 同时发起 n 个不同作品的加载（地址不同 → 不会命中单飞），返回服务端观察到的并发峰值。 */
    private int peakConcurrencyOfLoads(CoverService service, int n) throws Exception {
        ExecutorService pool = Executors.newFixedThreadPool(n);
        CountDownLatch ready = new CountDownLatch(1);
        try {
            List<Future<Optional<CoverService.CoverPayload>>> futures = IntStream.range(0, n)
                    .mapToObj(i -> pool.submit(() -> {
                        ready.await();
                        return service.load("W-" + i);
                    }))
                    .toList();
            ready.countDown();
            for (Future<Optional<CoverService.CoverPayload>> future : futures) {
                assertThat(future.get()).as("每张都该取到").isPresent();
            }
        } finally {
            pool.shutdownNow();
        }
        return maxActive.get();
    }

    private void startServer(long delayMillis) throws IOException {
        byte[] body = "fake-image-bytes".getBytes(StandardCharsets.UTF_8);
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        // 默认执行器是单线程的，会把并发请求排成队——那样测的就不是我们的闸门了
        server.setExecutor(Executors.newFixedThreadPool(8));
        server.createContext("/", exchange -> {
            maxActive.accumulateAndGet(active.incrementAndGet(), Math::max);
            try {
                Thread.sleep(delayMillis);
                exchange.getResponseHeaders().add("Content-Type", "image/jpeg");
                exchange.sendResponseHeaders(200, body.length);
                exchange.getResponseBody().write(body);
            } catch (InterruptedException ex) {
                Thread.currentThread().interrupt();
            } finally {
                active.decrementAndGet();
                exchange.close();
            }
        });
        server.start();
    }

    private CoverService service(List<String> fastHosts, int fastConcurrency) {
        WorkRepository repository = mock(WorkRepository.class);
        for (int i = 0; i < 8; i++) {
            String workId = "W-" + i;
            when(repository.findByWorkId(workId)).thenReturn(Optional.of(work(i)));
        }
        AppProperties properties = new AppProperties();
        AppProperties.Cover cover = properties.getCover();
        cover.setCacheDir(cacheDir.toString());
        cover.setAllowedHosts(List.of(hostPort()));
        // 把「间隔」调快，让用例只测并发这一维（间隔由另一个用例覆盖）
        cover.setRatePerSecond(20);
        cover.setMaxConcurrency(2);
        cover.setFastHosts(fastHosts);
        cover.setFastRatePerSecond(20);
        cover.setFastMaxConcurrency(fastConcurrency);
        cover.setTimeout(Duration.ofSeconds(5));
        return new CoverService(repository, properties);
    }

    private WorkRecord work(int i) {
        LocalDateTime now = LocalDateTime.now();
        return new WorkRecord((long) i, "W-" + i, "anime", "标题" + i, null, null,
                null, null, null, null,
                "http://" + hostPort() + "/cover-" + i + ".jpg",
                null, null, null, null, null, null, null,
                "otaku_site", "1", null, now, now, null);
    }

    private String hostPort() {
        return "127.0.0.1:" + server.getAddress().getPort();
    }
}
