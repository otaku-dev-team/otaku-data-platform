package com.otaku.console;

import org.springframework.stereotype.Component;

/**
 * 把登录主体解析成可见范围。**这是后台唯一能拿到 siteKey 的入口**。
 *
 * <p>刻意做成一个独立组件而不是在每个 Service 里 `principal.siteKey()` 直接用：
 * 一来"站点 → 来源"要查库，集中一次比散落各处好维护；
 * 二来审查越权时只需看这一个类和它的所有调用点，不必翻遍每个接口。
 */
@Component
public class ConsoleScopeResolver {

    private final SiteRepository siteRepository;

    public ConsoleScopeResolver(SiteRepository siteRepository) {
        this.siteRepository = siteRepository;
    }

    public ConsoleScope resolve(ConsolePrincipal principal) {
        return new ConsoleScope(principal.siteKey(), principal.siteName(),
                siteRepository.findSources(principal.siteKey()));
    }
}
