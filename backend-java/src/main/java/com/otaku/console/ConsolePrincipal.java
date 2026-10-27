package com.otaku.console;

/**
 * 后台请求的登录主体。**站点标识只能从这里来**，不能来自请求参数。
 *
 * <p>这不是风格问题：后台的每一条查询都要按站点过滤，过滤条件一旦可以是"调用方传的值"，
 * 越权就变成改一个字段。把站点塞进登录主体，等于把这件事从"每个接口各自小心"
 * 变成"只有一处能决定"。
 */
public record ConsolePrincipal(
        long adminPk,
        String adminId,
        String username,
        String displayName,
        String identitySource,
        String siteKey,
        String siteName
) {
}
