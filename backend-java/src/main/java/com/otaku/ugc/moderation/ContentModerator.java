package com.otaku.ugc.moderation;

/**
 * 内容审核器（#240 B2c「机器审核」接入位）。
 *
 * <p>平台侧**不自带**任何服务商 SDK：站点选谁，就在谁前面放一个适配器，
 * 让适配器把自家协议翻成 {@link ModerationRequest} / {@link ModerationResult}。
 * 这样换服务商只动部署配置，不动 Java 代码，也不用把某家的签名算法焊进业务里。
 *
 * <p>实现方只需要守两条：
 * <ol>
 *   <li>要么返回判定，要么抛 {@link ModerationUnavailableException}；
 *       <b>不要</b>自己决定「服务商挂了怎么办」——那是站点策略（{@code on-error}），由调用方统一处理；</li>
 *   <li>不要抛受检异常、不要吞异常后返回 {@code PASS}：吞掉会让「审核失败」看起来像「内容没问题」。</li>
 * </ol>
 */
public interface ContentModerator {

    /** 是否已接入。false 时调用方直接跳过，连日志都不打（默认就是这条路径）。 */
    boolean active();

    /**
     * 送审。
     *
     * @throws ModerationUnavailableException 服务商不可用（超时 / 非 2xx / 响应无法解析）
     */
    ModerationResult check(ModerationRequest request) throws ModerationUnavailableException;
}
