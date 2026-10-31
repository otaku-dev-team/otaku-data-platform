package com.otaku.ugc.moderation;

/**
 * 机器审核的三种判定（#240 B2c「机器审核」接入位）。
 *
 * <p>刻意只有三种。多一种「打分 + 阈值」就把服务商的策略语言搬进了平台，
 * 换服务商时要把阈值语义重新翻译一遍——判定越少，适配器越好写。
 */
public enum ModerationVerdict {

    /** 通过：按站点原有的发布策略走（先发后审 → published，先审后发 → pending）。 */
    PASS,

    /** 拿不准：一律转人工，落 {@code pending}，不管站点是哪种发布策略。 */
    REVIEW,

    /** 明确不合规：拒收，不落库，返回 {@code 400 CONTENT_REJECTED}。 */
    REJECT
}
