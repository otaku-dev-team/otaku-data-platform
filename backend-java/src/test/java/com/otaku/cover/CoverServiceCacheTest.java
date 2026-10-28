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
import java.nio.file.Files;
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
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 封面缓存的边界行为，对应 issue #39 讨论里暴露的两类问题：
 * 1. 200 但空 body 不能被当成"缓存成功"，否则这具空图会永久命中；
 * 2. 并发首访同一张图只能回源一次（单飞）。
 */
class CoverServiceCacheTest {

    @TempDir
    Path cacheDir;

    private HttpServer server;
    private final AtomicInteger hits = new AtomicInteger();

    @AfterEach
    void stopServer() {
        if (server != null) {
            server.stop(0);
        }
    }

    @Test
    @DisplayName("回源返回 200 但空 body：不落盘、不回填 key、返回空")
    void emptyBodyIsNotCached() throws Exception {
        startServer(new byte[0], 0);
        WorkRepository repository = mock(WorkRepository.class);
        when(repository.findByWorkId("W-1")).thenReturn(Optional.of(work()));
        CoverService service = new CoverService(repository, properties());

        Optional<CoverService.CoverPayload> payload = service.load("W-1");

        assertThat(payload).isEmpty();
        assertThat(hits.get()).isEqualTo(1);
        assertThat(Files.list(cacheDir).toList()).isEmpty();
        verify(repository, never()).updateCoverCache(anyLong(), anyString(), any());
    }

    @Test
    @DisplayName("并发首访同一封面：只回源一次，两个调用都拿到同一份字节")
    void concurrentFirstLoadFetchesOnce() throws Exception {
        byte[] body = "fake-webp-content".getBytes(StandardCharsets.UTF_8);
        // 让服务端慢一点，放大两个请求重叠的窗口
        startServer(body, 300);
        WorkRepository repository = mock(WorkRepository.class);
        when(repository.findByWorkId("W-1")).thenReturn(Optional.of(work()));
        CoverService service = new CoverService(repository, properties());

        ExecutorService pool = Executors.newFixedThreadPool(2);
        CountDownLatch ready = new CountDownLatch(1);
        try {
            List<Future<Optional<CoverService.CoverPayload>>> futures = IntStream.range(0, 2)
                    .mapToObj(i -> pool.submit(() -> {
                        ready.await();
                        return service.load("W-1");
                    }))
                    .toList();
            ready.countDown();

            for (Future<Optional<CoverService.CoverPayload>> future : futures) {
                Optional<CoverService.CoverPayload> payload = future.get();
                assertThat(payload).isPresent();
                assertThat(payload.get().body()).isEqualTo(body);
                assertThat(payload.get().contentType()).isEqualTo("image/webp");
            }
            assertThat(hits.get()).isEqualTo(1);
        } finally {
            pool.shutdownNow();
        }
    }

    private void startServer(byte[] body, long delayMillis) throws IOException {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/cover.jpg", exchange -> {
            hits.incrementAndGet();
            try {
                if (delayMillis > 0) {
                    Thread.sleep(delayMillis);
                }
                exchange.getResponseHeaders().add("Content-Type", "image/webp");
                exchange.sendResponseHeaders(200, body.length == 0 ? -1 : body.length);
                if (body.length > 0) {
                    exchange.getResponseBody().write(body);
                }
            } catch (InterruptedException ex) {
                Thread.currentThread().interrupt();
            } finally {
                exchange.close();
            }
        });
        server.start();
    }

    private AppProperties properties() {
        AppProperties properties = new AppProperties();
        AppProperties.Cover cover = properties.getCover();
        cover.setCacheDir(cacheDir.toString());
        cover.setAllowedHosts(List.of("127.0.0.1:" + server.getAddress().getPort()));
        cover.setRatePerSecond(10);
        cover.setMaxConcurrency(2);
        cover.setTimeout(Duration.ofSeconds(5));
        return properties;
    }

    private WorkRecord work() {
        LocalDateTime now = LocalDateTime.now();
        return new WorkRecord(1L, "W-1", "anime", "标题", null, null,
                null, null, null, null,
                "http://127.0.0.1:" + server.getAddress().getPort() + "/cover.jpg",
                null, null, null, null, null, null,
                "otaku_site", "1", null, now, now);
    }
}
