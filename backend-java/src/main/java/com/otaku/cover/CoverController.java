package com.otaku.cover;

import org.springframework.http.CacheControl;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RestController;

import java.time.Duration;
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

    public CoverController(CoverService coverService) {
        this.coverService = coverService;
    }

    @GetMapping("/api/covers/{workId}")
    public ResponseEntity<byte[]> cover(
            @PathVariable("workId") String workId,
            @RequestHeader(value = "If-None-Match", required = false) String ifNoneMatch) {

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
}
