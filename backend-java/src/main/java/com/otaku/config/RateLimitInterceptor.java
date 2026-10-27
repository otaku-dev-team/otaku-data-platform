package com.otaku.config;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.common.ErrorCode;
import com.otaku.common.ErrorResponse;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.servlet.HandlerInterceptor;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

/**
 * 公共读接口的按 IP 限流（Issue #188 形态 A，zm 2026-10-26 拍板「立刻做」）。
 *
 * <p>为什么是拦截器而不是 Filter：CORS 由 Spring MVC 的 handler mapping 处理，
 * 它在拦截器之前就已经把 {@code Access-Control-Allow-Origin} 写进响应。
 * 用 Filter 抢先返回 429 会丢掉这个头，浏览器侧看到的是"跨域错误"而不是"限流"——
 * 排查成本高得多。
 *
 * <p>只覆盖**公共读**路径；{@code /api/auth/**} 有自己的登录节流，
 * {@code /api/me/**} 与 {@code /api/console/**} 有令牌门槛，{@code /internal/**} 只有平台能调。
 *
 * <p>封面单独一个桶（默认更严）：封面会回源并缓存，被当图床的代价是带宽 + 回源，
 * 与列表查询不是一个量级。
 *
 * <p>IP 取 {@code remoteAddr}。当前后端直接对公网 :8080（没有反代），这是真实客户端地址；
 * 将来上 Nginx 后要打开 {@code trust-forwarded-for}，否则所有请求都会算到反代头上。
 */
@Component
public class RateLimitInterceptor implements HandlerInterceptor {

    private static final String COVER_PREFIX = "/api/covers/";
    /**
     * 桶容量除数：公共读 1/4（约 15 秒突发），封面 1/2。
     *
     * <p>封面为什么放宽：正常首屏就是 20 个封面，滚动时会连续取图；
     * 实测按 1/4（120/min → 突发 30）时，一次 130 张的连续请求里有 101 张被 429，
     * 正常浏览会被误伤。放宽到 1/2 后仍然是"每分钟 240 张"的硬上限，
     * 挡滥用靠的是持续速率，不是把正常请求卡死。
     */
    private static final int PUBLIC_BURST_DIVISOR = 4;
    private static final int COVER_BURST_DIVISOR = 2;

    private final IpRateLimiter limiter;
    private final ObjectMapper objectMapper;
    private final boolean enabled;
    private final int publicPerMinute;
    private final int coverPerMinute;
    private final boolean trustForwardedFor;

    public RateLimitInterceptor(IpRateLimiter limiter,
                                ObjectMapper objectMapper,
                                @Value("${app.rate-limit.enabled:true}") boolean enabled,
                                @Value("${app.rate-limit.public-per-minute:600}") int publicPerMinute,
                                @Value("${app.rate-limit.cover-per-minute:120}") int coverPerMinute,
                                @Value("${app.rate-limit.trust-forwarded-for:false}") boolean trustForwardedFor) {
        this.limiter = limiter;
        this.objectMapper = objectMapper;
        this.enabled = enabled;
        this.publicPerMinute = Math.max(1, publicPerMinute);
        this.coverPerMinute = Math.max(1, coverPerMinute);
        this.trustForwardedFor = trustForwardedFor;
    }

    @Override
    public boolean preHandle(HttpServletRequest request, HttpServletResponse response, Object handler)
            throws IOException {
        if (!enabled) {
            return true;
        }
        boolean cover = request.getRequestURI().startsWith(COVER_PREFIX);
        int perMinute = cover ? coverPerMinute : publicPerMinute;
        int burst = Math.max(1, perMinute / (cover ? COVER_BURST_DIVISOR : PUBLIC_BURST_DIVISOR));
        String bucket = cover ? "cover" : "public";
        String key = clientIp(request) + "|" + bucket;

        if (limiter.tryAcquire(key, perMinute, burst, System.nanoTime())) {
            return true;
        }
        // Retry-After 用 60 秒：令牌桶是连续补充的，精确到秒对客户端没有意义，
        // 给一个"最多等一分钟"的粗略值，配合指数退避足够。
        response.setHeader("Retry-After", "60");
        response.setStatus(ErrorCode.RATE_LIMITED.status().value());
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        response.setCharacterEncoding(StandardCharsets.UTF_8.name());
        objectMapper.writeValue(response.getWriter(),
                ErrorResponse.of(ErrorCode.RATE_LIMITED, "请求过于频繁，请稍后再试"));
        return false;
    }

    private String clientIp(HttpServletRequest request) {
        if (trustForwardedFor) {
            String forwarded = request.getHeader("X-Forwarded-For");
            if (forwarded != null && !forwarded.isBlank()) {
                int comma = forwarded.indexOf(',');
                return (comma < 0 ? forwarded : forwarded.substring(0, comma)).trim();
            }
        }
        String remote = request.getRemoteAddr();
        return remote == null ? "unknown" : remote;
    }
}
