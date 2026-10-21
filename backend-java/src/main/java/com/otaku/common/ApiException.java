package com.otaku.common;

/** 业务异常：携带契约错误码，由 GlobalExceptionHandler 转成统一信封。 */
public class ApiException extends RuntimeException {

    private final ErrorCode code;
    /** 需要附带 Retry-After 时填秒数（目前只有登录限流用），否则为 null。 */
    private final Integer retryAfterSeconds;

    public ApiException(ErrorCode code, String message) {
        this(code, message, null);
    }

    public ApiException(ErrorCode code, String message, Integer retryAfterSeconds) {
        super(message);
        this.code = code;
        this.retryAfterSeconds = retryAfterSeconds;
    }

    public ErrorCode code() {
        return code;
    }

    public Integer retryAfterSeconds() {
        return retryAfterSeconds;
    }

    public static ApiException badRequest(String message) {
        return new ApiException(ErrorCode.BAD_REQUEST, message);
    }

    public static ApiException workNotFound() {
        return new ApiException(ErrorCode.WORK_NOT_FOUND, "作品不存在");
    }
}
