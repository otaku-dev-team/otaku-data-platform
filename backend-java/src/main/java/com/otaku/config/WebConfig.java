package com.otaku.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.servlet.config.annotation.CorsRegistration;
import org.springframework.web.servlet.config.annotation.CorsRegistry;
import org.springframework.web.servlet.config.annotation.InterceptorRegistry;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * CORS（Issue #188：从「任意源」收窄到「配置的来源站 + 本地调试」）与公共读接口限流。
 *
 * <p>为什么不再用 {@code allowedOriginPatterns("*")}：它会**回显任意 Origin**，
 * 等于任何页面都能把封面代理当自家图床、把读接口当免费后端。
 * 这是「只给合作站」这个能力被放弃的起点，也是 zm 在 #188 明确要求收窄的一条。
 *
 * <p>默认值刻意是**空的**（fail-closed）：没有配置就没有跨域放行，
 * 但本地调试（localhost / 127.0.0.1 / ::1 任意端口）默认放行——那是开发机，
 * 不构成对外暴露。生产通过 {@code OTAKU_CORS_ALLOWED_ORIGINS} 显式列出站点。
 *
 * <p>手机与桌面端不发 Origin，不受 CORS 影响；这里只为 Web 页面（来源站 / Flutter Web）。
 */
@Configuration
public class WebConfig implements WebMvcConfigurer {

    private final RateLimitInterceptor rateLimitInterceptor;
    private final List<String> allowedOrigins;
    private final boolean allowLocalhost;

    public WebConfig(RateLimitInterceptor rateLimitInterceptor,
                     @Value("${app.cors.allowed-origins:}") String allowedOrigins,
                     @Value("${app.cors.allow-localhost:true}") boolean allowLocalhost) {
        this.rateLimitInterceptor = rateLimitInterceptor;
        this.allowedOrigins = parseOrigins(allowedOrigins);
        this.allowLocalhost = allowLocalhost;
    }

    @Override
    public void addCorsMappings(CorsRegistry registry) {
        CorsRegistration registration = registry.addMapping("/api/**")
                .allowedMethods("GET")
                .maxAge(3600);
        // 空列表 = 不写该维度；两个维度都空时 Spring 会拒绝所有跨域请求（fail-closed）。
        if (!allowedOrigins.isEmpty()) {
            registration.allowedOrigins(allowedOrigins.toArray(String[]::new));
        }
        if (allowLocalhost) {
            // Spring 的端口通配语法是 `:[*]`，写成 `:*` 不会被任何 Origin 命中
            // （实测：配置来源放行，localhost:5173 却仍被 403 拒）。
            registration.allowedOriginPatterns(
                    "http://localhost:[*]", "http://127.0.0.1:[*]", "http://[::1]:[*]");
        }
    }

    @Override
    public void addInterceptors(InterceptorRegistry registry) {
        registry.addInterceptor(rateLimitInterceptor)
                // 只拦公共读：/api/auth 有登录节流，/api/me 与 /api/console 有令牌门槛，
                // /internal 只有平台能调。逐条列出而不是 /api/**，避免把新接口"默认"卷进来。
                .addPathPatterns("/api/works/**", "/api/tags/**", "/api/schedule/**",
                        "/api/articles/**", "/api/covers/**", "/api/app/**");
    }

    private static List<String> parseOrigins(String raw) {
        if (raw == null || raw.isBlank()) {
            return List.of();
        }
        List<String> origins = new ArrayList<>();
        Arrays.stream(raw.split(","))
                .map(String::trim)
                .filter(s -> !s.isEmpty())
                .forEach(origins::add);
        return List.copyOf(origins);
    }
}
