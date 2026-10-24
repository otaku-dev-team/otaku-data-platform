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
                // 不自动跟随：自动跟随只校验起始 URI，一次 302 就能绕出白名单。
                // 重定向在 send() 里逐跳校验（见该方法注释）。
                .followRedirects(HttpClient.Redirect.NEVER)
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

            HttpResponse<InputStream> response = send(uri);
            if (response == null) {
                return Optional.empty();
            }

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

    /** 最多跟随几跳重定向；每跳都过白名单，把「一次 302 绕出白名单」这条路堵死。 */
    private static final int MAX_REDIRECTS = 3;

    private static boolean isRedirect(int status) {
        return status == 301 || status == 302 || status == 303 || status == 307 || status == 308;
    }

    /**
     * 按白名单逐跳跟随重定向，返回**最终**响应；任何一跳不合规就返回 {@code null}。
     *
     * <p>为什么不用 {@code HttpClient.Redirect.NORMAL}：自动跟随只校验**起始** URI，
     * 一个 302 就能把请求带到任意主机——白名单形同虚设。这里每跳重新校验协议与 host:port。
     *
     * <p>限流按「一次取图」算一个槽位，不按跳数算：跳数由 {@link #MAX_REDIRECTS} 封顶，
     * 对来源站的额外压力最多 3 倍，可接受；换来的是不会因为一次跳转把令牌桶打散。
     */
    private HttpResponse<InputStream> send(URI start) throws IOException, InterruptedException {
        URI uri = start;
        for (int hop = 0; hop <= MAX_REDIRECTS; hop++) {
            HttpRequest request = HttpRequest.newBuilder(uri)
                    .timeout(properties.getCover().getTimeout())
                    .header("User-Agent", "otaku-data-platform/0.1.0")
                    .GET()
                    .build();
            HttpResponse<InputStream> response =
                    httpClient.send(request, HttpResponse.BodyHandlers.ofInputStream());
            if (!isRedirect(response.statusCode())) {
                return response;
            }
            String location = response.headers().firstValue("Location").orElse(null);
            closeQuietly(response.body());
            if (location == null || location.isBlank()) {
                log.warn("封面重定向缺少 Location，放弃：{}", uri);
                return null;
            }
            URI next = uri.resolve(location.trim());
            String scheme = next.getScheme();
            if (scheme == null || !(scheme.equalsIgnoreCase("http") || scheme.equalsIgnoreCase("https"))) {
                log.warn("封面重定向到不支持的协议，放弃：{} -> {}", uri, next);
                return null;
            }
            if (!isAllowed(next)) {
                log.warn("封面重定向目标不在白名单，放弃：{} -> {}", uri, next);
                return null;
            }
            uri = next;
        }
        log.warn("封面重定向超过 {} 跳，放弃：{}", MAX_REDIRECTS, start);
        return null;
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

    /**
     * 白名单校验：**列表为空 = 全部拒绝**（fail-closed）。
     *
     * <p>早期是「为空 = 不限制」，理由是方便本地开发。但封面回源的目标地址直接来自导入载荷，
     * 一旦配置漏写，就等于把任意 URL 变成服务端出站请求——失败方向搞反了。
     * 现在漏配的表现是封面全部 404 + 每次一条 WARN，可见、可查，不会静默放开。
     *
     * <p>包内可见是为了直接单测边界（端口、默认端口、大小写），不必起 HTTP 服务。
     */
    boolean isAllowed(URI uri) {
        var allowed = properties.getCover().getAllowedHosts();
        if (allowed == null || allowed.isEmpty()) {
            return false;
        }
        String host = uri.getHost();
        if (host == null || host.isBlank()) {
            return false;
        }
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
