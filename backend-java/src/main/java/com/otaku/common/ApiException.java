package com.otaku.common;

/** 业务异常：携带契约错误码，由 GlobalExceptionHandler 转成统一信封。 */
public class ApiException extends RuntimeException {

    private final ErrorCode code;

    public ApiException(ErrorCode code, String message) {
        super(message);
        this.code = code;
    }

    public ErrorCode code() {
        return code;
    }

    public static ApiException badRequest(String message) {
        return new ApiException(ErrorCode.BAD_REQUEST, message);
    }

    public static ApiException workNotFound() {
        return new ApiException(ErrorCode.WORK_NOT_FOUND, "作品不存在");
    }
}
