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

    /** 阶段 2：口令错误或用户不存在（不区分两者，避免枚举账号）。 */
    INVALID_CREDENTIALS(HttpStatus.UNAUTHORIZED),
    /** 阶段 2：用户名已被占用。 */
    USERNAME_TAKEN(HttpStatus.CONFLICT),
    /** 阶段 2：改状态时收藏已不存在（对应验收 C11，客户端应提示刷新而不是自动重新收藏）。 */
    COLLECTION_REQUIRED(HttpStatus.CONFLICT),
    BATCH_TOO_LARGE(HttpStatus.PAYLOAD_TOO_LARGE),
    RATE_LIMITED(HttpStatus.TOO_MANY_REQUESTS),
    INTERNAL(HttpStatus.INTERNAL_SERVER_ERROR);

    private final HttpStatus status;

    ErrorCode(HttpStatus status) {
        this.status = status;
    }

    public HttpStatus status() {
        return status;
    }
}
