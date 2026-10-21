package com.otaku.cover;

import com.otaku.config.AppProperties;
import com.otaku.work.WorkRecord;
import com.otaku.work.WorkRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.time.Duration;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.HexFormat;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.LockSupport;

/**
 * 封面代理 + 本地缓存。
 *
 * 为什么一定要代理（契约 2.1、8.1 的实测结论）：
 * - 来源站 /media/* 不带 Access-Control-Allow-Origin，Flutter Web 直连必然跨域失败；
 * - 来源站 Cache-Control 只有约 43 分钟，客户端拿不到长缓存；
 * - 来源站是小站，不能让所有客户端反复回源。
 *
 * 行为：
 * - 缓存命中直接服务，不回源；
 * - 未命中才回源一次，遵守 2 并发 + 1–2 req/s 的限流，落盘后再服务；
 * - 失败不缓存、不抛错，返回空由控制器给 404，客户端显示占位图。
 */
@Service
public class CoverService {

    private static final Logger log = LoggerFactory.getLogger(CoverService.class);

    private static final Map<String, String> EXT_BY_TYPE = Map.of(
            "image/jpeg", ".jpg",
            "image/jpg", ".jpg",
            "image/png", ".png",
            "image/webp", ".webp",
            "image/gif", ".gif",
            "image/avif", ".avif");

    private static final Map<String, String> TYPE_BY_EXT = Map.of(
            ".jpg", "image/jpeg",
            ".png", "image/png",
            ".webp", "image/webp",
            ".gif", "image/gif",
            ".avif", "image/avif");

    public record CoverPayload(byte[] body, String contentType, String etag) {
    }

    private final WorkRepository workRepository;
    private final AppProperties properties;
    private final Path cacheDir;
    private final Semaphore concurrency;
    private final long minIntervalNanos;
    private final HttpClient httpClient;

    /** 单飞表：封面地址 → 正在进行的回源。完成后立刻移除，不占内存。 */
    private final ConcurrentHashMap<String, CompletableFuture<Optional<CoverPayload>>> inflight =
            new ConcurrentHashMap<>();
    private static final long FLIGHT_TIMEOUT_SECONDS = 20;

    private long nextSlotNanos = System.nanoTime();

    public CoverService(WorkRepository workRepository, AppProperties properties) {
        this.workRepository = workRepository;
        this.properties = properties;
        AppProperties.Cover cover = properties.getCover();
        this.cacheDir = Path.of(cover.getCacheDir()).toAbsolutePath().normalize();
        this.concurrency = new Semaphore(Math.max(1, cover.getMaxConcurrency()));
        int rate = Math.max(1, cover.getRatePerSecond());
        this.minIntervalNanos = Duration.ofSeconds(1).toNanos() / rate;
        this.httpClient = HttpClient.newBuilder()
                .connectTimeout(cover.getTimeout())
                .followRedirects(HttpClient.Redirect.NORMAL)
                .build();
        try {
            Files.createDirectories(cacheDir);
        } catch (IOException ex) {
            throw new UncheckedIOException("封面缓存目录不可用：" + cacheDir, ex);
        }
    }

    public Optional<CoverPayload> load(String workId) {
        Optional<WorkRecord> found = workRepository.findByWorkId(workId);
        if (found.isEmpty()) {
            return Optional.empty();
        }
        WorkRecord work = found.get();
        if (work.coverSourceUrl() == null) {
            return Optional.empty();
        }

        // 1) 优先用这条作品自己记着的 key
        String cacheKey = work.coverCacheKey();
        if (cacheKey != null) {
            Optional<CoverPayload> hit = readCache(cacheKey);
            if (hit.isPresent()) {
                return hit;
            }
        }

        // 2) key 为空（或文件已丢）时，按来源地址的哈希去磁盘上找同名前缀的文件。
        //    这是 issue #39 的核心：缓存文件名只由 URL 决定，同一张图被多条作品引用时，
        //    只要文件已在盘上就不该再回源；只认 cover_cache_key 会让回源次数放大到作品数。
        String hash = sha256Hex(work.coverSourceUrl());
        Optional<String> onDisk = findCachedKeyByHash(hash);
        if (onDisk.isPresent()) {
            String key = onDisk.get();
            Optional<CoverPayload> hit = readCache(key);
            if (hit.isPresent()) {
                if (cacheKey == null) {
                    // 顺手把 key 回填，避免下次再扫目录
                    workRepository.updateCoverCache(work.id(), key, LocalDateTime.now(ZoneOffset.UTC));
                    log.debug("封面缓存按哈希命中并回填 key：work={} key={}", workId, key);
                }
                return hit;
            }
        }
        return downloadOnce(work);
    }

    /**
     * 单飞：同一张封面在同一时刻只允许一次回源，其余请求等这一次的结果。
     *
     * 为什么需要：缓存未命中时，滚动列表会同时触发多个请求，若各自回源，
     * 同一张图会被下载 N 次（issue #39 讨论里提到的并发场景）。限流能保证不打爆来源站，
     * 但没必要把同一份字节传两遍。
     */
    private Optional<CoverPayload> downloadOnce(WorkRecord work) {
        String flightKey = work.coverSourceUrl();
        CompletableFuture<Optional<CoverPayload>> mine = new CompletableFuture<>();
        CompletableFuture<Optional<CoverPayload>> running = inflight.putIfAbsent(flightKey, mine);
        if (running != null) {
            try {
                return running.get(FLIGHT_TIMEOUT_SECONDS, TimeUnit.SECONDS);
            } catch (InterruptedException ex) {
                Thread.currentThread().interrupt();
                return Optional.empty();
            } catch (Exception ex) {
                log.warn("等待同封面并发回源失败 url={}：{}", flightKey, ex.toString());
                return Optional.empty();
            }
        }
        try {
            Optional<CoverPayload> result = download(work);
            mine.complete(result);
            return result;
        } catch (RuntimeException ex) {
            mine.complete(Optional.empty());
            throw ex;
        } finally {
            inflight.remove(flightKey, mine);
        }
    }

    private Optional<CoverPayload> readCache(String cacheKey) {
        Path cached = resolveSafely(cacheKey);
        if (cached == null || !Files.isReadable(cached)) {
            return Optional.empty();
        }
        try {
            return Optional.of(new CoverPayload(Files.readAllBytes(cached),
                    contentTypeOf(cacheKey), etagOf(cacheKey)));
        } catch (IOException ex) {
            log.warn("读取封面缓存失败，将回源：{}", ex.getMessage());
            return Optional.empty();
        }
    }

    /** 在缓存目录里找 {@code <hash>.<ext>} 形式的文件；找到就返回完整文件名（即 cacheKey）。 */
    private Optional<String> findCachedKeyByHash(String hash) {
        try (DirectoryStream<Path> entries = Files.newDirectoryStream(cacheDir, hash + ".*")) {
            for (Path entry : entries) {
                if (Files.isReadable(entry)) {
                    return Optional.of(entry.getFileName().toString());
                }
            }
        } catch (IOException ex) {
            log.warn("扫描封面缓存目录失败：{}", ex.getMessage());
        }
        return Optional.empty();
    }

    private Optional<CoverPayload> download(WorkRecord work) {
        URI uri;
        try {
            uri = URI.create(work.coverSourceUrl());
        } catch (IllegalArgumentException ex) {
            log.warn("封面地址非法，跳过：{}", work.coverSourceUrl());
            return Optional.empty();
        }
        String scheme = uri.getScheme();
        if (scheme == null || !(scheme.equalsIgnoreCase("http") || scheme.equalsIgnoreCase("https"))) {
            log.warn("封面地址协议不受支持，跳过：{}", uri);
            return Optional.empty();
        }
        if (!isAllowed(uri)) {
            log.warn("封面来源不在白名单，跳过：{}", uri);
            return Optional.empty();
        }

        boolean acquired = false;
        try {
            concurrency.acquire();
            acquired = true;
            acquireRateSlot();

            HttpRequest request = HttpRequest.newBuilder(uri)
                    .timeout(properties.getCover().getTimeout())
                    .header("User-Agent", "otaku-data-platform/0.1.0")
                    .GET()
                    .build();
            HttpResponse<InputStream> response =
                    httpClient.send(request, HttpResponse.BodyHandlers.ofInputStream());

            if (response.statusCode() != 200) {
                closeQuietly(response.body());
                log.warn("封面回源失败 status={} url={}", response.statusCode(), uri);
                return Optional.empty();
            }
            String contentType = response.headers().firstValue("Content-Type")
                    .map(value -> value.split(";")[0].trim().toLowerCase(Locale.ROOT))
                    .orElse("image/jpeg");
            if (!contentType.startsWith("image/")) {
                closeQuietly(response.body());
                log.warn("封面回源返回非图片类型 {} url={}", contentType, uri);
                return Optional.empty();
            }

            byte[] bytes = readBounded(response.body(), properties.getCover().getMaxBytes());
            if (bytes == null) {
                log.warn("封面超过大小上限 {}，不缓存：{}", properties.getCover().getMaxBytes(), uri);
                return Optional.empty();
            }
            if (bytes.length == 0) {
                // 200 但空 body：不能落盘也不能回填 key，否则会把这具"空图"永久缓存下去
                log.warn("封面回源返回空内容，不缓存：{}", uri);
                return Optional.empty();
            }

            String cacheKey = sha256Hex(work.coverSourceUrl())
                    + EXT_BY_TYPE.getOrDefault(contentType, ".bin");
            writeAtomically(cacheKey, bytes);
            workRepository.updateCoverCache(work.id(), cacheKey, LocalDateTime.now(ZoneOffset.UTC));

            return Optional.of(new CoverPayload(bytes,
                    EXT_BY_TYPE.containsKey(contentType) ? contentType : "image/jpeg",
                    etagOf(cacheKey)));
        } catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
            return Optional.empty();
        } catch (Exception ex) {
            log.warn("封面回源异常 url={}：{}", uri, ex.toString());
            return Optional.empty();
        } finally {
            if (acquired) {
                concurrency.release();
            }
        }
    }

    /** 令牌桶式的最小间隔限速；来源站要求 1–2 req/s。 */
    private synchronized void acquireRateSlot() {
        long now = System.nanoTime();
        long wait = nextSlotNanos - now;
        if (wait > 0) {
            LockSupport.parkNanos(wait);
        }
        long slot = Math.max(now, nextSlotNanos);
        nextSlotNanos = slot + minIntervalNanos;
    }

    private boolean isAllowed(URI uri) {
        var allowed = properties.getCover().getAllowedHosts();
        if (allowed == null || allowed.isEmpty()) {
            return true;
        }
        String host = uri.getHost();
        int port = uri.getPort();
        String effectivePort = String.valueOf(port > 0 ? port
                : ("https".equalsIgnoreCase(uri.getScheme()) ? 443 : 80));
        String key = host + ":" + effectivePort;
        return allowed.stream().anyMatch(entry -> entry != null && entry.trim().equalsIgnoreCase(key));
    }

    private Path resolveSafely(String cacheKey) {
        Path path = cacheDir.resolve(cacheKey).normalize();
        return path.startsWith(cacheDir) ? path : null;
    }

    private void writeAtomically(String cacheKey, byte[] bytes) throws IOException {
        Path target = resolveSafely(cacheKey);
        if (target == null) {
            throw new IOException("非法的缓存键：" + cacheKey);
        }
        Path temp = Files.createTempFile(cacheDir, "cover-", ".tmp");
        Files.write(temp, bytes);
        try {
            Files.move(temp, target, StandardCopyOption.REPLACE_EXISTING,
                    StandardCopyOption.ATOMIC_MOVE);
        } catch (IOException ex) {
            Files.move(temp, target, StandardCopyOption.REPLACE_EXISTING);
        }
    }

    /** 读满上限即放弃，避免被超大响应拖住。 */
    private static byte[] readBounded(InputStream in, long maxBytes) throws IOException {
        try (in) {
            ByteArrayOutputStream out = new ByteArrayOutputStream(64 * 1024);
            byte[] buffer = new byte[16 * 1024];
            long total = 0;
            int read;
            while ((read = in.read(buffer)) != -1) {
                total += read;
                if (total > maxBytes) {
                    return null;
                }
                out.write(buffer, 0, read);
            }
            return out.toByteArray();
        }
    }

    private static String contentTypeOf(String cacheKey) {
        int dot = cacheKey.lastIndexOf('.');
        String ext = dot < 0 ? "" : cacheKey.substring(dot).toLowerCase(Locale.ROOT);
        return TYPE_BY_EXT.getOrDefault(ext, "image/jpeg");
    }

    private static String etagOf(String cacheKey) {
        return "\"" + cacheKey + "\"";
    }

    private static String sha256Hex(String value) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            return HexFormat.of().formatHex(digest.digest(value.getBytes(java.nio.charset.StandardCharsets.UTF_8)));
        } catch (Exception ex) {
            throw new IllegalStateException("SHA-256 不可用", ex);
        }
    }

    private static void closeQuietly(InputStream in) {
        try {
            in.close();
        } catch (IOException ignored) {
            // 关闭失败无需处理
        }
    }
}
