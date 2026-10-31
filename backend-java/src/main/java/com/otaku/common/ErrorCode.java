package com.otaku.common;

import org.springframework.http.HttpStatus;

/**
 * 第一阶段统一错误码，见 docs/stage1-minimal-contract.md 第 7 节。
 * 客户端与 Python 都按字符串 code 分支，枚举名即 wire 值。
 */
public enum ErrorCode {

    UNAUTHORIZED(HttpStatus.UNAUTHORIZED),
    BAD_REQUEST(HttpStatus.BAD_REQUEST),
    WORK_NOT_FOUND(HttpStatus.NOT_FOUND),
    /** 契约第 7 节的 404 只定义了 WORK_NOT_FOUND；批次查询需要区分，故补充此码。 */
    BATCH_NOT_FOUND(HttpStatus.NOT_FOUND),
    /** 资讯不存在。与上面两个同模式：404 需要区分是哪种实体，客户端据此显示不同空状态。 */
    ARTICLE_NOT_FOUND(HttpStatus.NOT_FOUND),
    /** 评论不存在（后台审核用；客户端侧的删除按幂等 204 处理，不用这个码）。 */
    COMMENT_NOT_FOUND(HttpStatus.NOT_FOUND),
    /** 点评不存在（#240 B2c⑥）。与评论分开：客户端要区分「这条点评没了」和「这条评论没了」。 */
    REVIEW_NOT_FOUND(HttpStatus.NOT_FOUND),
    /** 同一作品已经点评过（一人一条）。客户端应引导去编辑，而不是重新提交。 */
    REVIEW_EXISTS(HttpStatus.CONFLICT),
    /**
     * 机器审核判定内容不合规（#240 B2c「机器审核」接入位）。
     *
     * <p>用 400 而不是 422：客户端对 4xx 的处理只有「普通错误」一档，
     * 多一个状态码要多改一次客户端；用 code 区分就够——客户端据此把提示换成
     * 「修改后再发」，而不是笼统的「请求有误」。**不落库**，用户改完可以直接重发。
     */
    CONTENT_REJECTED(HttpStatus.BAD_REQUEST),

    /** 阶段 2：口令错误或用户不存在（不区分两者，避免枚举账号）。 */
    INVALID_CREDENTIALS(HttpStatus.UNAUTHORIZED),
    /**
     * 账号被站点管理员禁用（站主后台 Issue #144）。
     *
     * <p>用 403 而不是 401：401 会让客户端以为"令牌过期，重新登录就好"，
     * 于是反复弹登录框、反复失败。403 才说得清"你这个人现在不能进"。
     * 前提是**口令已经验证通过**，因此不构成账号枚举。
     */
    USER_DISABLED(HttpStatus.FORBIDDEN),
    /** 越权：登录态有效，但目标资源不属于自己的站点。契约要求 403（不是 404）。 */
    FORBIDDEN(HttpStatus.FORBIDDEN),
    /** 站主后台：账号不存在。与"存在但属于别人站点"（403）分开，便于排查。 */
    USER_NOT_FOUND(HttpStatus.NOT_FOUND),
    /** 平台侧：站点不存在（/internal/sites/{key}/... 找不到这个 site_key）。 */
    SITE_NOT_FOUND(HttpStatus.NOT_FOUND),
    /** 平台侧：站主不存在（/internal/site-admins/{adminId}/... 找不到这个 admin_id）。 */
    ADMIN_NOT_FOUND(HttpStatus.NOT_FOUND),
    /** 阶段 2：用户名已被占用。 */
    USERNAME_TAKEN(HttpStatus.CONFLICT),
    /** 阶段 2：改状态时收藏已不存在（对应验收 C11，客户端应提示刷新而不是自动重新收藏）。 */
    COLLECTION_REQUIRED(HttpStatus.CONFLICT),
    /** W1.3b：登记的推送设备数超过每账号上限（方案 §4.3 第 5 点）。 */
    DEVICE_LIMIT_EXCEEDED(HttpStatus.CONFLICT),
    BATCH_TOO_LARGE(HttpStatus.PAYLOAD_TOO_LARGE),
    RATE_LIMITED(HttpStatus.TOO_MANY_REQUESTS),
    /**
     * 阶段 2 账号绑定（#242）：站点侧暂不可用（超时 / 5xx / 未配置）。
     *
     * <p>与 {@link #INVALID_CREDENTIALS} 分开：票据失效等**授权失败**用 401，
     * 客户端引导重走授权就能解决；站点本身挂了/超时重走授权也没用，
     * 用 503 让客户端提示「稍后再试」，避免把用户推进必然失败的重试循环。
     */
    SITE_UNAVAILABLE(HttpStatus.SERVICE_UNAVAILABLE),
    INTERNAL(HttpStatus.INTERNAL_SERVER_ERROR);

    private final HttpStatus status;

    ErrorCode(HttpStatus status) {
        this.status = status;
    }

    public HttpStatus status() {
        return status;
    }
}
