package com.otaku.auth;

import com.otaku.auth.dto.LoginRequest;
import com.otaku.auth.dto.SessionResponse;
import com.otaku.auth.dto.UserDto;
import com.otaku.user.UserRecord;
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
 * 客户端账号接口，对齐契约 §4.1–§4.3。
 * 注册不在这里：契约 §11.7 明确首期不开放自助注册，账号由内部建号接口创建。
 */
@RestController
@RequestMapping("/api/auth")
public class AuthController {

    private final AuthService authService;

    public AuthController(AuthService authService) {
        this.authService = authService;
    }

    @PostMapping("/login")
    public SessionResponse login(@RequestBody LoginRequest request) {
        return authService.login(request);
    }

    @GetMapping("/me")
    public UserDto me(@RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user) {
        return AuthService.toDto(user);
    }

    /**
     * 撤销当前令牌。契约 §4.3：已失效的令牌再调一次也返回 204，
     * 所以这里不依赖鉴权属性，自己读头即可，且永不返回 401。
     */
    @PostMapping("/logout")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void logout(HttpServletRequest request) {
        authService.logout(AuthFilter.bearerToken(request));
    }
}
