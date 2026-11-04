package com.otaku.view;

import com.otaku.auth.AuthFilter;
import com.otaku.user.UserRecord;
import com.otaku.view.dto.ViewRequest;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestAttribute;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

/**
 * 浏览打点。需要 Bearer 会话令牌（{@code AuthFilter} 覆盖 {@code /api/me/**}）。
 *
 * <p>为什么单独一个端点而不是在详情接口里顺手记：见 {@link ViewService} 的说明——
 * 公开详情路径上没有登录态，硬加就是给最热的读路径加一次会话查询。
 *
 * <p>返回 204 而不是 200：客户端不需要回执，打点是「发了就忘」的动作；
 * 重复提交是**正常情况**（同一个人反复打开同一页），不是错误。
 */
@RestController
@RequestMapping("/api/me/views")
public class ViewController {

    private final ViewService service;

    public ViewController(ViewService service) {
        this.service = service;
    }

    @PostMapping
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void record(@RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
                       @RequestBody ViewRequest request) {
        service.record(user, request.workId());
    }
}
