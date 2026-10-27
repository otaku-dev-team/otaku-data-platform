package com.otaku.console;

import java.util.List;

/**
 * 一次后台请求的「可见范围」：站点键 + 该站点的数据来源。
 *
 * <p>所有后台查询都从它取过滤条件，而不是从请求里读。构造它的唯一入口是
 * {@link ConsoleScopeResolver#resolve}，而它只接受登录主体——所以"改请求参数就能看别站"这条路在代码里不存在。
 */
public record ConsoleScope(String siteKey, String siteName, List<String> sources) {

    public ConsoleScope {
        sources = sources == null ? List.of() : List.copyOf(sources);
    }

    public boolean hasSources() {
        return !sources.isEmpty();
    }
}
