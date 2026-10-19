import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import 'error_interceptor.dart';

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
  ref.onDispose(() => dio.close());
  return dio;
});
