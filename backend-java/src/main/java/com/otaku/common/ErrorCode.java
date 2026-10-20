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
