import 'package:dio/dio.dart';

import 'api_exception.dart';

/// 把 dio 抛出的各种异常统一换成 [ApiException]，挂在 `DioException.error` 上。
/// 这样仓储层只需要 `on ApiException`，不用再判断超时、断网、状态码。
///
/// 顺带处理 429：公共读接口按 IP 限流后，`Retry-After` 是服务端给的**唯一**
/// 正确退避时间（窗口是按 IP 的，自己拍一个固定值等不到它开）。这里只做
/// **短等待的一次自动重试**——等待超过 [maxAutoRetryWait] 就直接交给页面，
/// 因为让用户对着骨架屏干等十几秒，比看到「N 秒后再试」更糟。
class ErrorInterceptor extends Interceptor {
  ErrorInterceptor({
    this.retryFetch,
    this.maxAutoRetryWait = const Duration(seconds: 3),
    this.wait,
  });

  /// 重发请求的入口（生产里是 `dio.fetch`）。为 null 表示不自动重试。
  final Future<Response<dynamic>> Function(RequestOptions options)? retryFetch;

  /// 超过这个等待时间就不自动重试，交给 UI 显示倒计时。
  final Duration maxAutoRetryWait;

  /// 测试注入用；默认真的等。
  final Future<void> Function(Duration duration)? wait;

  /// 打在这个请求上的「已经因 429 重试过一次」标记，避免无限重试。
  static const String _retriedKey = 'otaku.rateLimitRetried';

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final api = ApiException.fromDio(err);

    final retryAfter = api.retryAfter;
    final options = err.requestOptions;
    final canRetry =
        retryFetch != null &&
        api.code == ApiErrorCode.rateLimited &&
        retryAfter != null &&
        retryAfter <= maxAutoRetryWait &&
        options.method.toUpperCase() == 'GET' &&
        options.extra[_retriedKey] != true;

    if (!canRetry) {
      handler.reject(_wrap(err, api));
      return;
    }

    options.extra[_retriedKey] = true;
    await (wait ?? Future<void>.delayed)(retryAfter);

    try {
      handler.resolve(await retryFetch!(options));
    } on DioException catch (retryError) {
      handler.reject(_wrap(retryError, ApiException.fromDio(retryError)));
    }
  }

  static DioException _wrap(DioException err, ApiException api) {
    return DioException(
      requestOptions: err.requestOptions,
      response: err.response,
      type: err.type,
      error: api,
      stackTrace: err.stackTrace,
      message: api.message,
    );
  }
}
