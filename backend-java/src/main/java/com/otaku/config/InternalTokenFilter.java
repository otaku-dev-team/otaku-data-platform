package com.otaku.config;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.common.ErrorCode;
import com.otaku.common.ErrorResponse;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

/**
 * 内部接口的令牌校验，拦 {@code /internal/**} 与指标端点（{@code /actuator/metrics}、
 * {@code /actuator/prometheus}）。
 *
 * 设计要点：
 * - 令牌只从配置/环境变量读取，绝不落日志（下面只打印路径与来源 IP）；
 * - 常数时间比较，避免按字节计时推断令牌；
 * - 未配置令牌时一律拒绝（安全默认），而不是放行；
 * - 与面向客户端的接口分开认证：客户端不持有这个令牌，见 backend-java/README.md 的边界。
 *
 * <p>为什么指标也要令牌：8080 是公网可达的，{@code /actuator/prometheus} 会暴露每个端点的
 * QPS、错误率与延迟分布——排障需要它，但没必要让外面看得见。{@code /actuator/health} 保持公开：
 * 巡检脚本与负载均衡探针都要用，且它只回 UP/DOWN。
 */
@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 10)
public class InternalTokenFilter extends OncePerRequestFilter {

    public static final String HEADER = "X-Internal-Token";

    private static final Logger log = LoggerFactory.getLogger(InternalTokenFilter.class);

    private final AppProperties properties;
    private final ObjectMapper objectMapper;

    public InternalTokenFilter(AppProperties properties, ObjectMapper objectMapper) {
        this.properties = properties;
        this.objectMapper = objectMapper;
        if (properties.getInternalToken().isBlank()) {
            log.warn("app.internal-token 未配置：/internal/** 全部返回 401。"
                    + "联调前请设置环境变量 OTAKU_INTERNAL_TOKEN。");
        }
    }

    /** 指标端点：{@code /actuator/metrics} 与它的子路径、以及 {@code /actuator/prometheus}。 */
    private static boolean isMetricsPath(String path) {
        return path.equals("/actuator/prometheus")
                || path.equals("/actuator/metrics")
                || path.startsWith("/actuator/metrics/");
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        String path = request.getRequestURI().substring(request.getContextPath().length());
        return !path.startsWith("/internal/") && !isMetricsPath(path);
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response,
                                    FilterChain chain) throws ServletException, IOException {
        String expected = properties.getInternalToken();
        String actual = request.getHeader(HEADER);

        if (expected.isBlank()) {
            reject(response, "内部导入接口未配置令牌，已禁用");
            return;
        }
        if (actual == null || !constantTimeEquals(expected, actual)) {
            log.warn("内部接口鉴权失败：{} {} from {}", request.getMethod(), request.getRequestURI(),
                    request.getRemoteAddr());
            reject(response, "内部令牌缺失或无效");
            return;
        }
        chain.doFilter(request, response);
    }

    private void reject(HttpServletResponse response, String message) throws IOException {
        response.setStatus(ErrorCode.UNAUTHORIZED.status().value());
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        response.setCharacterEncoding(StandardCharsets.UTF_8.name());
        objectMapper.writeValue(response.getWriter(),
                ErrorResponse.of(ErrorCode.UNAUTHORIZED, message));
    }

    private static boolean constantTimeEquals(String expected, String actual) {
        return MessageDigest.isEqual(
                expected.getBytes(StandardCharsets.UTF_8),
                actual.getBytes(StandardCharsets.UTF_8));
    }
}
