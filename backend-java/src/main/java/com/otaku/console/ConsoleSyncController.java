package com.otaku.console;

import com.otaku.console.dto.ConsoleDtos;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestAttribute;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 同步状态：最近一次运行时间/成败、近期运行明细、失败条目（提案 §2.1 第 3 条）。
 *
 * <p>只读。后台**不提供**触发同步的入口（提案 §9：手动触发属二期）——
 * 那会让站主拿到一个能打满来源站的按钮，而限速责任在平台侧。
 * 「补齐入口」= 看得见的失败 source_id + 一条平台侧命令，写在响应的 {@code retry_hint} 里。
 */
@RestController
@RequestMapping("/api/console/sync")
public class ConsoleSyncController {

    private final ConsoleSyncService syncService;
    private final ConsoleScopeResolver scopeResolver;

    public ConsoleSyncController(ConsoleSyncService syncService, ConsoleScopeResolver scopeResolver) {
        this.syncService = syncService;
        this.scopeResolver = scopeResolver;
    }

    @GetMapping
    public ConsoleDtos.SyncStatus status(
            @RequestAttribute(ConsoleAuthFilter.ATTRIBUTE_PRINCIPAL) ConsolePrincipal principal) {
        return syncService.status(scopeResolver.resolve(principal));
    }
}
