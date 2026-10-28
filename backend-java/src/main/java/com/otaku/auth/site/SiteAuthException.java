package com.otaku.auth.site;

/**
 * 站点令牌交换失败。
 *
 * <p>{@code upstreamDetail} 是站点错误信封（FastAPI 的 {@code {"detail": ...}}）原文，
 * **只进服务端日志**——契约 §7 明确不得把站点 detail 透传给客户端：
 * 一避免泄漏上游实现细节，二保证客户端只认平台错误契约（{code, message}）。
 */
public class SiteAuthException extends RuntimeException {

    private final SiteAuthFailure failure;
    private final String upstreamDetail;

    public SiteAuthException(SiteAuthFailure failure, String message, String upstreamDetail) {
        super(message);
        this.failure = failure;
        this.upstreamDetail = upstreamDetail;
    }

    public SiteAuthFailure failure() {
        return failure;
    }

    /** 站点错误原文，仅供服务端日志；调用方不得把它放进任何客户端可见的响应。 */
    public String upstreamDetail() {
        return upstreamDetail;
    }
}
