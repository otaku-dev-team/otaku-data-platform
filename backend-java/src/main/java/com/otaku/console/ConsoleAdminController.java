package com.otaku.console;

import com.otaku.console.dto.ConsoleDtos;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestAttribute;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * 本站站主名单（二期：站主自助增删）。
 *
 * <p>路径与用户管理并列（{@code /api/console/admins}），不接受任何站点参数：
 * 站点只来自登录态。一个站主能加的永远是**本站**的人。
 */
@RestController
@RequestMapping("/api/console/admins")
public class ConsoleAdminController {

    private final ConsoleAdminService service;

    public ConsoleAdminController(ConsoleAdminService service) {
        this.service = service;
    }

    @GetMapping
    public List<ConsoleDtos.AdminItem> list(
            @RequestAttribute(ConsoleAuthFilter.ATTRIBUTE_PRINCIPAL) ConsolePrincipal principal) {
        return service.list(principal);
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public ConsoleDtos.AdminCreated create(
            @RequestAttribute(ConsoleAuthFilter.ATTRIBUTE_PRINCIPAL) ConsolePrincipal principal,
            @RequestBody ConsoleDtos.AdminCreateRequest request) {
        return service.create(principal, request);
    }

    @PostMapping("/{adminId}/disable")
    public ConsoleDtos.AdminStatusChange disable(
            @RequestAttribute(ConsoleAuthFilter.ATTRIBUTE_PRINCIPAL) ConsolePrincipal principal,
            @PathVariable("adminId") String adminId) {
        return service.disable(principal, adminId);
    }

    @PostMapping("/{adminId}/enable")
    public ConsoleDtos.AdminStatusChange enable(
            @RequestAttribute(ConsoleAuthFilter.ATTRIBUTE_PRINCIPAL) ConsolePrincipal principal,
            @PathVariable("adminId") String adminId) {
        return service.enable(principal, adminId);
    }
}
