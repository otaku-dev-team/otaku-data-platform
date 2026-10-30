package com.otaku.auth;

import com.otaku.user.UserRecord;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.RequestAttribute;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

/**
 * 账号自身的动作（#240 B2c⑤）。
 *
 * <p>为什么不塞进 {@link AuthController}：那个类整体挂在 {@code /api/auth} 下，
 * 而注销按契约是 {@code DELETE /api/me}——路径不同，挂一起只能靠绝对路径绕，
 * 反而看不出这个端点属于谁。
 */
@RestController
public class AccountController {

    private final AuthService authService;

    public AccountController(AuthService authService) {
        this.authService = authService;
    }

    /**
     * 注销自己的账号。
     *
     * <p>语义（zm 2026-10-30 定）：**匿名化保留**——评论不删，作者显示「已注销用户」，楼层不塌；
     * 物理删由站点开关控制（默认关）。
     *
     * <p>注销后所有设备的会话立刻失效；再登录会失败（账号已 disabled），所以不需要重复确认。
     */
    @DeleteMapping("/api/me")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void delete(@RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user) {
        authService.deleteAccount(user);
    }
}
