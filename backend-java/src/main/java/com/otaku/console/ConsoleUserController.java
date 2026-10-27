package com.otaku.console;

import com.otaku.common.PageResponse;
import com.otaku.console.dto.ConsoleDtos;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestAttribute;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * 本站用户：列表 + 禁用/解禁（提案 §2.1 第 2 条，首版只这两件事）。
 *
 * <p>禁用是 {@code POST .../disable} 而不是 {@code PUT status=disabled}：
 * 动作语义更清楚，也避免调用方传一个没校验过的状态字符串把账号改成别的值。
 */
@RestController
@RequestMapping("/api/console/users")
public class ConsoleUserController {

    private final ConsoleUserService userService;

    public ConsoleUserController(ConsoleUserService userService) {
        this.userService = userService;
    }

    @GetMapping
    public PageResponse<ConsoleDtos.UserItem> list(
            @RequestAttribute(ConsoleAuthFilter.ATTRIBUTE_PRINCIPAL) ConsolePrincipal principal,
            @RequestParam(name = "status", required = false) String status,
            @RequestParam(name = "q", required = false) String q,
            @RequestParam(name = "page", defaultValue = "1") int page,
            @RequestParam(name = "page_size", defaultValue = "20") int pageSize) {
        return userService.list(principal, status, q, page, pageSize);
    }

    @PostMapping("/{userId}/disable")
    public ConsoleDtos.UserStatusChange disable(
            @RequestAttribute(ConsoleAuthFilter.ATTRIBUTE_PRINCIPAL) ConsolePrincipal principal,
            @PathVariable("userId") String userId,
            @RequestBody(required = false) ConsoleDtos.UserStatusRequest request) {
        return userService.disable(principal, userId, request == null ? null : request.reason());
    }

    @PostMapping("/{userId}/enable")
    public ConsoleDtos.UserStatusChange enable(
            @RequestAttribute(ConsoleAuthFilter.ATTRIBUTE_PRINCIPAL) ConsolePrincipal principal,
            @PathVariable("userId") String userId) {
        return userService.enable(principal, userId);
    }
}
