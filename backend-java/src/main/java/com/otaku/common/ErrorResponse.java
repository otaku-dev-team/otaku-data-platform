package com.otaku.common;

/**
 * 统一错误信封：{"error":{"code":"WORK_NOT_FOUND","message":"作品不存在"}}
 * 接口②③④共用，见 docs/stage1-minimal-contract.md 第 7 节。
 */
public record ErrorResponse(ErrorBody error) {

    public record ErrorBody(String code, String message) {
    }

    public static ErrorResponse of(ErrorCode code, String message) {
        return new ErrorResponse(new ErrorBody(code.name(), message));
    }
}
