package com.otaku.ugc.moderation;

/**
 * 服务商不可用：超时、非 2xx、响应看不懂。
 *
 * <p>单独一个类型，是为了让调用方能把它和「判定为不合规」分开：
 * 前者按站点策略兜底（{@code on-error}），后者直接拒收。混成一种，「服务商宕机」
 * 会被记成「内容违规」，用户和审核员都会看不懂。
 */
public class ModerationUnavailableException extends RuntimeException {

    public ModerationUnavailableException(String message) {
        super(message);
    }

    public ModerationUnavailableException(String message, Throwable cause) {
        super(message, cause);
    }
}
