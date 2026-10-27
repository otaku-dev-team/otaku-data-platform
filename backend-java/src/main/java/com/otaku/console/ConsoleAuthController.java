package com.otaku.console;

import com.otaku.auth.AuthFilter;
import com.otaku.console.dto.ConsoleDtos;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestAttribute;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

/**
 * 站主后台的登录态接口。
 *
 * <p>和客户端 {@code /api/auth/**} 是两套完全独立的东西：不同的表、不同的令牌、不同的有效期
 * （后台 12 小时 / 客户端 30 天）。站主令牌不能调客户端接口，客户端令牌也进不了后台。
 */
@RestController
@RequestMapping("/api/console/auth")
public class ConsoleAuthController {

    private final ConsoleAuthService authService;

    public ConsoleAuthController(ConsoleAuthService authService) {
        this.authService = authService;
    }

    @PostMapping("/login")
    public ConsoleDtos.SessionResponse login(@RequestBody ConsoleDtos.LoginRequest request) {
        return authService.login(request);
    }

    @GetMapping("/me")
    public ConsoleDtos.MeResponse me(@RequestAttribute(ConsoleAuthFilter.ATTRIBUTE_PRINCIPAL) ConsolePrincipal principal) {
        return new ConsoleDtos.MeResponse(
                new ConsoleDtos.SiteView(principal.siteKey(), principal.siteName()),
                new ConsoleDtos.AdminView(principal.adminId(), principal.username(),
                        principal.displayName(), principal.identitySource()));
    }

    /** 与客户端一致：不带令牌或令牌已失效也返回 204，退出流程不该卡在 401 上。 */
    @PostMapping("/logout")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void logout(HttpServletRequest request) {
        authService.logout(AuthFilter.bearerToken(request));
    }
}
