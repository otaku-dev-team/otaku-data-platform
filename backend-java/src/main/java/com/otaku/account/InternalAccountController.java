package com.otaku.account;

import com.otaku.account.dto.CreateAccountRequest;
import com.otaku.auth.AuthService;
import com.otaku.auth.dto.UserDto;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

/**
 * 内部建号接口（契约附录 A）。首期不开放自助注册，联调账号 A/B 由此创建。
 *
 * 鉴权沿用阶段 1 的 X-Internal-Token（InternalTokenFilter 已覆盖 /internal/**），
 * 客户端不应持有该令牌，因此这个接口也不对外暴露。
 */
@RestController
@RequestMapping("/internal/accounts")
public class InternalAccountController {

    private final AuthService authService;

    public InternalAccountController(AuthService authService) {
        this.authService = authService;
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public UserDto create(@RequestBody CreateAccountRequest request) {
        return authService.createAccount(request.username(), request.password(), request.siteKey());
    }
}
