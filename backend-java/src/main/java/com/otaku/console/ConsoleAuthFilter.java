package com.otaku.console;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.auth.AuthFilter;
import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.common.ErrorResponse;
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
 * 后台鉴权：只拦 {@code /api/console/**}。
 *
 * <p>与 {@link com.otaku.auth.AuthFilter}（客户端）和 {@link com.otaku.config.InternalTokenFilter}
 * （内部接口）三套凭据互不通用，路径也互不重叠——一个令牌泄露不会顺带打开另一面。
 *
 * <p>放行的两个例外：
 * <ul>
 *   <li>{@code POST /api/console/auth/login}：当然不能要求先登录；</li>
 *   <li>{@code POST /api/console/auth/logout}：与客户端一致，令牌已失效也返回 204，
 *       退出流程不该卡在 401 分支上（幂等）。</li>
 * </ul>
 */
@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 30)
public class ConsoleAuthFilter extends OncePerRequestFilter {

    public static final String ATTRIBUTE_PRINCIPAL = "consolePrincipal";
    public static final String ATTRIBUTE_TOKEN = "consoleToken";

    private final ConsoleAuthService authService;
    private final ObjectMapper objectMapper;

    public ConsoleAuthFilter(ConsoleAuthService authService, ObjectMapper objectMapper) {
        this.authService = authService;
        this.objectMapper = objectMapper;
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        String path = request.getRequestURI().substring(request.getContextPath().length());
        if (!path.startsWith("/api/console/")) {
            return true;
        }
        return path.equals("/api/console/auth/login") || path.equals("/api/console/auth/logout");
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response,
                                    FilterChain chain) throws ServletException, IOException {
        String token = AuthFilter.bearerToken(request);
        Optional<ConsolePrincipal> principal;
        try {
            principal = authService.authenticate(token);
        } catch (ApiException ex) {
            // 停用的站主/站点：403 且说明原因，不是静悄悄当作"未登录"
            write(response, ex.code(), ex.getMessage());
            return;
        }
        if (principal.isEmpty()) {
            write(response, ErrorCode.UNAUTHORIZED, "未登录或会话已失效");
            return;
        }
        request.setAttribute(ATTRIBUTE_PRINCIPAL, principal.get());
        request.setAttribute(ATTRIBUTE_TOKEN, token);
        chain.doFilter(request, response);
    }

    private void write(HttpServletResponse response, ErrorCode code, String message) throws IOException {
        response.setStatus(code.status().value());
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        response.setCharacterEncoding(StandardCharsets.UTF_8.name());
        objectMapper.writeValue(response.getWriter(), ErrorResponse.of(code, message));
    }
}
