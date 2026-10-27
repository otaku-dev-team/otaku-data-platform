package com.otaku.console;

import com.otaku.console.dto.ConsoleDtos;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestAttribute;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 数据概览：本站作品数、字段覆盖率、同步摘要（提案 §2.1 第 1 条）。
 *
 * <p>路径里没有 {@code site_id}，请求里也没有——站点来自登录态（{@link ConsolePrincipal}）。
 * 想让接口"支持多站点"而加一个可选参数，等于把隔离交给调用方的自觉。
 */
@RestController
@RequestMapping("/api/console/overview")
public class ConsoleOverviewController {

    private final ConsoleOverviewService overviewService;

    public ConsoleOverviewController(ConsoleOverviewService overviewService) {
        this.overviewService = overviewService;
    }

    @GetMapping
    public ConsoleDtos.Overview overview(
            @RequestAttribute(ConsoleAuthFilter.ATTRIBUTE_PRINCIPAL) ConsolePrincipal principal) {
        return overviewService.overview(principal);
    }
}
