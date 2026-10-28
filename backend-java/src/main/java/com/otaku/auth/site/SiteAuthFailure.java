package com.otaku.auth.site;

/**
 * 站点 OAuth 客户端失败原因。分两档，决定平台返回给客户端的错误类别：
 *
 * <ul>
 *   <li>{@link #AUTH_FAILED}：站点明确拒绝（票据无效/过期/已用、client 凭据错）——
 *       平台返回 401，客户端引导重走授权；</li>
 *   <li>{@link #UNAVAILABLE}：网络失败、超时、站点 5xx、响应不符合契约——
 *       重走授权也解决不了，平台返回 503。</li>
 * </ul>
 */
public enum SiteAuthFailure {
    AUTH_FAILED,
    UNAVAILABLE
}
