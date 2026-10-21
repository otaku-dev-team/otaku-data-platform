import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import '../diagnostics/frame_stats.dart';
import '../storage/token_store.dart';
import 'api_exception.dart';
import 'auth_token_interceptor.dart';
import 'error_interceptor.dart';
import 'session_expiry.dart';

/// 全局唯一的 dio 实例配置。超时值按"来源站慢、后端会做缓存"的场景给，
/// 不要为了等封面下载把 receiveTimeout 调到 30 秒以上。
Dio createDio({String? baseUrl}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: baseUrl ?? AppConfig.baseUrl,
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      headers: const {'Accept': 'application/json'},
      // 4xx/5xx 一律走 onError，交给 ErrorInterceptor 解析信封。
    ),
  );

  dio.interceptors.add(ErrorInterceptor());

  // 性能统计开关关着时 noteRequest() 立刻返回，等于没有这个拦截器。
  if (FrameStats.enabled) {
    dio.interceptors.add(
      InterceptorsWrapper(onRequest: (options, handler) {
        FrameStats.noteRequest();
        handler.next(options);
      }),
    );
  }

  if (kDebugMode) {
    dio.interceptors.add(
      LogInterceptor(
        requestBody: false,
        responseBody: false,
        logPrint: (line) => debugPrint('[dio] $line'),
      ),
    );
  }

  return dio;
}

final dioProvider = Provider<Dio>((ref) {
  final dio = createDio();

  // 令牌注入。排在链路最前：请求一进来就该带好鉴权头，
  // 后面的拦截器（日志、错误解析）看到的都是最终要发出去的样子。
  dio.interceptors.insert(
    0,
    AuthTokenInterceptor(() => ref.read(tokenStoreProvider).read()),
  );

  // 令牌失效的统一出口：任何请求收到 401 UNAUTHORIZED 都通知认证层清会话。
  //
  // 必须插在 `ErrorInterceptor` **之前**：那个拦截器用 `handler.reject` 结束链路，
  // 排在它后面的 onError 根本不会执行。这里只发信号，清理交给认证层。
  dio.interceptors.insert(
    0,
    InterceptorsWrapper(
      onError: (error, handler) {
        final exception = ApiException.fromAny(error);
        // 只有 `UNAUTHORIZED` 才算会话失效；`INVALID_CREDENTIALS` 是登录密码错，
        // 走这里会把用户已有的会话踢掉。
        if (exception.code == ApiErrorCode.unauthorized && ref.mounted) {
          ref.read(sessionExpiryProvider.notifier).notifyExpired();
        }
        handler.next(error);
      },
    ),
  );

  ref.onDispose(() => dio.close());
  return dio;
});
