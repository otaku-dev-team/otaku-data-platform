package com.otaku.auth.site;

/**
 * 站点 OAuth 令牌交换的出站口。
 *
 * <p>抽成接口的原因：{@code HttpSiteAuthClient} 是真出站（HTTP 调站点），
 * 集成测试里换成桩实现，MockMvc 全链路就能在不动网络的情况下
 * 覆盖「换 token → 建/查映射 → 建会话」的全部业务分支。
 */
public interface SiteAuthClient {

    /**
     * 用一次性票据换站点令牌与用户资料。
     *
     * @throws SiteAuthException 站点拒绝或不可用时；失败原因看 {@link SiteAuthException#failure()}
     */
    SiteTokenResponse exchange(String ticket);
}
