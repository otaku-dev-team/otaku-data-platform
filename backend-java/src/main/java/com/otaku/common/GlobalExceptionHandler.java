package com.otaku.common;

import jakarta.servlet.http.HttpServletRequest;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.MissingServletRequestParameterException;
import org.springframework.web.bind.ServletRequestBindingException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.method.annotation.MethodArgumentTypeMismatchException;
import org.springframework.web.HttpMediaTypeNotSupportedException;
import org.springframework.web.HttpRequestMethodNotSupportedException;
import org.springframework.web.servlet.resource.NoResourceFoundException;

import java.util.stream.Collectors;

/**
 * 所有面向客户端的错误都收敛成{"error":{"code","message"}}。
 * 注意：/api/covers/** 由 CoverController 自己返回 404 空体，不走这里。
 */
@RestControllerAdvice
public class GlobalExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(GlobalExceptionHandler.class);

    @ExceptionHandler(ApiException.class)
    public ResponseEntity<ErrorResponse> handleApi(ApiException ex) {
        ResponseEntity.BodyBuilder builder = ResponseEntity.status(ex.code().status());
        if (ex.retryAfterSeconds() != null) {
            builder.header(HttpHeaders.RETRY_AFTER, String.valueOf(ex.retryAfterSeconds()));
        }
        return builder.body(ErrorResponse.of(ex.code(), ex.getMessage()));
    }

    @ExceptionHandler({
            HttpMessageNotReadableException.class,
            MissingServletRequestParameterException.class,
            MethodArgumentTypeMismatchException.class,
            MethodArgumentNotValidException.class,
            ServletRequestBindingException.class
    })
    public ResponseEntity<ErrorResponse> handleBadRequest(Exception ex) {
        return ResponseEntity.badRequest()
                .body(ErrorResponse.of(ErrorCode.BAD_REQUEST, "请求格式或参数不合法：" + rootMessage(ex)));
    }

    @ExceptionHandler(NoResourceFoundException.class)
    public ResponseEntity<ErrorResponse> handleNoResource(NoResourceFoundException ex) {
        return ResponseEntity.status(ErrorCode.WORK_NOT_FOUND.status())
                .body(ErrorResponse.of(ErrorCode.WORK_NOT_FOUND, "资源不存在"));
    }

    @ExceptionHandler(HttpRequestMethodNotSupportedException.class)
    public ResponseEntity<ErrorResponse> handleMethodNotAllowed(HttpRequestMethodNotSupportedException ex) {
        // #345：方法不支持是「客户端用错」，不是服务端故障——不打 ERROR、不诱导重试。
        var builder = ResponseEntity.status(ErrorCode.METHOD_NOT_ALLOWED.status());
        // RFC 9110 §15.5.6 要求 405 带 Allow，否则调用方只知道「不能用这个方法」，
        // 不知道能用哪个——「405 但不给 Allow」等于把猜测留给客户端。
        var supported = ex.getSupportedHttpMethods();
        if (supported != null && !supported.isEmpty()) {
            builder.header(HttpHeaders.ALLOW,
                    supported.stream().map(HttpMethod::name).sorted().collect(Collectors.joining(", ")));
        }
        return builder.body(ErrorResponse.of(ErrorCode.METHOD_NOT_ALLOWED, "请求方法不被支持"));
    }

    @ExceptionHandler(HttpMediaTypeNotSupportedException.class)
    public ResponseEntity<ErrorResponse> handleUnsupportedMediaType(HttpMediaTypeNotSupportedException ex) {
        // 与 405 同族（#345 顺带项）：Content-Type 不对也是「客户端用错」，
        // 之前落到兜底 500 并刷 ERROR 堆栈。415 让调用方知道该改报文格式
        // （与 406 的区别：406 是我们产不出客户端要的格式，415 是客户端给错了格式）。
        //
        // 不往响应里塞「支持哪些类型」：`Accept` 是请求头（客户端声明要什么），
        // 放在响应里语义相反；`Accept-Post` 只对 POST 有效，且没有客户端在读。
        // 契约里每个端点的 consumes 已经写清了。
        return ResponseEntity.status(ErrorCode.UNSUPPORTED_MEDIA_TYPE.status())
                .body(ErrorResponse.of(ErrorCode.UNSUPPORTED_MEDIA_TYPE, "请求体格式不被支持"));
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<ErrorResponse> handleUnknown(Exception ex, HttpServletRequest request) {
        log.error("未处理异常 {} {}", request.getMethod(), request.getRequestURI(), ex);
        return ResponseEntity.status(ErrorCode.INTERNAL.status())
                .body(ErrorResponse.of(ErrorCode.INTERNAL, "服务端错误"));
    }

    private static String rootMessage(Exception ex) {
        Throwable cursor = ex;
        while (cursor.getCause() != null && cursor.getCause() != cursor) {
            cursor = cursor.getCause();
        }
        String message = cursor.getMessage();
        return message == null ? "参数错误" : message;
    }
}
