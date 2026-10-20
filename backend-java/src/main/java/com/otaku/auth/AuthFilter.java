package com.otaku.auth;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.common.ErrorCode;
import com.otaku.common.ErrorResponse;
import com.otaku.user.UserRecord;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Optional;

/**
 * 客户端会话鉴权，只拦 /api/me/** 与 /api/auth/me。
 *
 * 与 InternalTokenFilter 分离：客户端用 Bearer 会话令牌，Python 用 X-Internal-Token，
 * 两套凭据互不通用（backend-java/README.md 的边界要求）。
 */
@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 20)
public class AuthFilter extends OncePerRequestFilter {

    public static final String ATTRIBUTE_USER = "authUser";
    public static final String ATTRIBUTE_TOKEN = "authToken";
    private static final String BEARER = "Bearer ";

    private final AuthService authService;
    private final ObjectMapper objectMapper;

    public AuthFilter(AuthService authService, ObjectMapper objectMapper) {
        this.authService = authService;
        this.objectMapper = objectMapper;
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        String path = request.getRequestURI().substring(request.getContextPath().length());
        return !(path.equals("/api/auth/me")
                || path.equals("/api/auth/logout")
                || path.startsWith("/api/me/"));
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response,
                                    FilterChain chain) throws ServletException, IOException {
        String token = extractToken(request);
        Optional<UserRecord> user = authService.authenticate(token);
        if (user.isEmpty()) {
            reject(response);
            return;
        }
        request.setAttribute(ATTRIBUTE_USER, user.get());
        request.setAttribute(ATTRIBUTE_TOKEN, token);
        chain.doFilter(request, response);
    }

    private static String extractToken(HttpServletRequest request) {
        String header = request.getHeader("Authorization");
        if (header == null || !header.startsWith(BEARER)) {
            return null;
        }
        String token = header.substring(BEARER.length()).trim();
        return token.isEmpty() ? null : token;
    }

    private void reject(HttpServletResponse response) throws IOException {
        response.setStatus(ErrorCode.UNAUTHORIZED.status().value());
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        response.setCharacterEncoding(StandardCharsets.UTF_8.name());
        objectMapper.writeValue(response.getWriter(),
                ErrorResponse.of(ErrorCode.UNAUTHORIZED, "未登录或会话已失效"));
    }
}
