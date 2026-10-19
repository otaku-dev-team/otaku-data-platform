import 'package:dio/dio.dart';

import 'api_exception.dart';

/// 把 dio 抛出的各种异常统一换成 [ApiException]，挂在 `DioException.error` 上。
/// 这样仓储层只需要 `on ApiException`，不用再判断超时、断网、状态码。
class ErrorInterceptor extends Interceptor {
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final api = ApiException.fromDio(err);
    handler.reject(
      DioException(
        requestOptions: err.requestOptions,
        response: err.response,
        type: err.type,
        error: api,
        stackTrace: err.stackTrace,
        message: api.message,
      ),
    );
  }
}
