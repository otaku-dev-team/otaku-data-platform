package com.otaku.ugc.moderation;

/**
 * 送审内容。
 *
 * <p>只送**正文**，不送用户名、作品名、IP。理由：机器审核的合规责任主体是网站，
 * 送出去的字段越少，数据出境的边界越好解释；真正需要上下文才能判的场景
 * （比如「这部作品本来就带暴力标签」）交给人工，不靠把整页数据喂给服务商。
 *
 * @param siteKey 站点键，服务商侧按站点分开计费 / 分开策略时要用
 * @param scene   场景：{@code comment}（评论与回复）/ {@code review}（点评）
 * @param text    正文
 */
public record ModerationRequest(String siteKey, String scene, String text) {
}
