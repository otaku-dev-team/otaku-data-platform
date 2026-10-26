package com.otaku.cover;

import com.otaku.config.AppProperties;
import org.springframework.http.CacheControl;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RestController;

import java.net.URI;
import java.time.Duration;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.Optional;

/**
 * 封面出口。
 *
 * 路径由 Java 侧定义（契约要求"代理 + 缓存"，但 openapi.yaml 里没有这个端点，
 * 见 backend-java/README.md 的待确认事项）。设计取向：
 * - 不需要鉴权：Flutter 用 CachedNetworkImage 直接 GET，且在 <img>/图片加载上下文里不方便加头；
 * - 找不到 / 来源不可用都返回 404 空体，客户端已有占位图兜底；
 * - 长缓存 + ETag，客户端第二次起不再下载。
 */
@RestController
public class CoverController {

    private static final CacheControl CACHE = CacheControl.maxAge(Duration.ofDays(30)).cachePublic();
    private static final int MAX_WORK_ID_LENGTH = 64;

    private final CoverService coverService;
    private final AppProperties properties;

    public CoverController(CoverService coverService, AppProperties properties) {
        this.coverService = coverService;
        this.properties = properties;
    }

    @GetMapping("/api/covers/{workId}")
    public ResponseEntity<byte[]> cover(
            @PathVariable("workId") String workId,
            @RequestHeader(value = "If-None-Match", required = false) String ifNoneMatch,
            @RequestHeader(value = "Referer", required = false) String referer) {

        // 防盗链放在最前面：被别站引用时连库都不用查。
        if (!isRefererAllowed(referer)) {
            return ResponseEntity.status(404).cacheControl(CacheControl.noStore()).build();
        }
        if (workId == null || workId.isBlank() || workId.length() > MAX_WORK_ID_LENGTH) {
            return ResponseEntity.notFound().build();
        }
        Optional<CoverService.CoverPayload> payload = coverService.load(workId.trim());
        if (payload.isEmpty()) {
            return ResponseEntity.status(404).cacheControl(CacheControl.noStore()).build();
        }

        CoverService.CoverPayload cover = payload.get();
        if (ifNoneMatch != null && ifNoneMatch.contains(cover.etag())) {
            return ResponseEntity.status(304)
                    .eTag(cover.etag())
                    .cacheControl(CACHE)
                    .build();
        }
        return ResponseEntity.ok()
                .contentType(MediaType.parseMediaType(cover.contentType()))
                .eTag(cover.etag())
                .cacheControl(CACHE)
                .body(cover.body());
    }

    /**
     * 防盗链判断：**没带 Referer 一律放行**，带了就必须在白名单里。
     *
     * <p>为什么「没带就放行」：Flutter 的 CachedNetworkImage、curl、服务端调用都不发 Referer，
     * 拦掉会把 App 的封面全部打空。真正要挡的是「浏览器带着别人的页面地址来取图」——
     * 那种请求一定带 Referer。
     *
     * <p>白名单为空 = 不限制（保持历史行为，避免默认配置改变线上表现）。
     */
    boolean isRefererAllowed(String referer) {
        List<String> allowed = properties.getCover().getAllowedReferers();
        if (allowed == null || allowed.isEmpty()) {
            return true;
        }
        if (referer == null || referer.isBlank()) {
            return true;
        }
        Optional<String> actual = originOf(referer);
        if (actual.isEmpty()) {
            // 解析不出 host 的 Referer（如 about:blank）按可疑处理
            return false;
        }
        return allowed.stream()
                .filter(Objects::nonNull)
                .map(String::trim)
                .filter(entry -> !entry.isEmpty())
                .map(CoverController::originOf)
                .flatMap(Optional::stream)
                .anyMatch(actual.get()::equals);
    }

    /** 归一成 {@code scheme://host:port}：省略端口按默认端口补齐，host/scheme 忽略大小写。 */
    private static Optional<String> originOf(String url) {
        try {
            URI uri = URI.create(url.trim());
            String scheme = uri.getScheme();
            String host = uri.getHost();
            if (scheme == null || host == null) {
                return Optional.empty();
            }
            int port = uri.getPort();
            String effectivePort = String.valueOf(port > 0 ? port
                    : ("https".equalsIgnoreCase(scheme) ? 443 : 80));
            return Optional.of(scheme.toLowerCase(Locale.ROOT) + "://"
                    + host.toLowerCase(Locale.ROOT) + ":" + effectivePort);
        } catch (IllegalArgumentException ex) {
            return Optional.empty();
        }
    }
}
