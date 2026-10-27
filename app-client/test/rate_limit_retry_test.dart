import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/core/network/error_interceptor.dart';

/// 限流（429）下的客户端行为。
///
/// 后端 #217 起对公共读按 IP 限流，契约里 `Retry-After` 是强制的。
/// 客户端要做两件事：把等待时间解析出来、短等待自动重试一次。
/// 这两件不做，用户看到的就是「请求太频繁」+ 自己反复点重试——正好又落在窗口里。
///
/// 用假 `HttpClientAdapter` 而不是假 Interceptor：**请求阶段的 reject 不会经过
/// 同链条上其他拦截器的 onError**，只有适配器抛出的真实 4xx/5xx 才会，
/// 用假拦截器测出来的是假通过。
void main() {
  group('Retry-After 解析', () {
    test('秒数', () {
      expect(ApiException.parseRetryAfter('120'), const Duration(seconds: 120));
      expect(ApiException.parseRetryAfter('0'), Duration.zero);
    });

    test('HTTP-date 也认（RFC 9110 允许两种写法）', () {
      final at = DateTime.now().toUtc().add(const Duration(seconds: 90));
      final parsed = ApiException.parseRetryAfter(HttpDate.format(at));
      expect(parsed, isNotNull);
      expect(parsed!.inSeconds, inInclusiveRange(88, 90));
    });

    test('写坏的头上不猜，返回 null', () {
      expect(ApiException.parseRetryAfter('soon'), isNull);
      expect(ApiException.parseRetryAfter('  '), isNull);
      expect(ApiException.parseRetryAfter(null), isNull);
    });
  });

  group('429 的提示文案', () {
    test('带上服务端给的秒数', () {
      final api = ApiException.fromResponse(
        Response<dynamic>(
          requestOptions: RequestOptions(path: '/api/works'),
          statusCode: 429,
          headers: Headers.fromMap({
            'retry-after': ['7'],
          }),
          data: {
            'error': {'code': 'RATE_LIMITED', 'message': 'too many'},
          },
        ),
      );

      expect(api.code, ApiErrorCode.rateLimited);
      expect(api.retryAfter, const Duration(seconds: 7));
      expect(api.userMessage, contains('7 秒'));
    });

    test('没有 Retry-After 时退回通用说法', () {
      final api = ApiException.fromResponse(
        Response<dynamic>(
          requestOptions: RequestOptions(path: '/api/works'),
          statusCode: 429,
          data: {
            'error': {'code': 'RATE_LIMITED', 'message': 'too many'},
          },
        ),
      );
      expect(api.retryAfter, isNull);
      expect(api.userMessage, '请求太频繁了，请稍后再试');
    });
  });

  group('短等待自动重试', () {
    test('Retry-After 2 秒：等 2 秒重试一次并成功', () async {
      final adapter = _FakeAdapter((options, call) {
        if (call == 1) return _rateLimitedJson(2);
        return _okJson();
      });

      final dio = _dio(adapter);
      final waits = <Duration>[];
      dio.interceptors.add(
        ErrorInterceptor(
          retryFetch: (options) => dio.fetch(options),
          wait: (duration) async => waits.add(duration),
        ),
      );

      final response = await dio.get<Map<String, dynamic>>('/api/works');

      expect(response.statusCode, 200);
      expect(adapter.calls, 2);
      expect(waits.single, const Duration(seconds: 2));
    });

    test('等 60 秒太久：不自动重试，交给页面显示倒计时', () async {
      final adapter = _FakeAdapter((options, call) => _rateLimitedJson(60));
      final dio = _dio(adapter);
      final waits = <Duration>[];
      dio.interceptors.add(
        ErrorInterceptor(
          retryFetch: (options) => dio.fetch(options),
          wait: (duration) async => waits.add(duration),
        ),
      );

      await expectLater(
        dio.get<Map<String, dynamic>>('/api/works'),
        throwsA(isA<DioException>()),
      );

      expect(adapter.calls, 1);
      expect(waits, isEmpty);
    });

    test('只重试一次：第二次还是 429 就停', () async {
      final adapter = _FakeAdapter((options, call) => _rateLimitedJson(1));
      final dio = _dio(adapter);
      dio.interceptors.add(
        ErrorInterceptor(
          retryFetch: (options) => dio.fetch(options),
          wait: (duration) async {},
        ),
      );

      await expectLater(
        dio.get<Map<String, dynamic>>('/api/works'),
        throwsA(isA<DioException>()),
      );

      expect(adapter.calls, 2);
    });

    test('非 GET 不重试（写操作重发不是「再试一次」那么便宜）', () async {
      final adapter = _FakeAdapter((options, call) => _rateLimitedJson(1));
      final dio = _dio(adapter);
      dio.interceptors.add(
        ErrorInterceptor(
          retryFetch: (options) => dio.fetch(options),
          wait: (duration) async {},
        ),
      );

      await expectLater(
        dio.post<Map<String, dynamic>>('/api/me/collections/W-1'),
        throwsA(isA<DioException>()),
      );

      expect(adapter.calls, 1);
    });
  });
}

Dio _dio(_FakeAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test.local'));
  dio.httpClientAdapter = adapter;
  return dio;
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handlerFor);

  final ResponseBody Function(RequestOptions options, int call) handlerFor;

  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return handlerFor(options, calls);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _rateLimitedJson(int seconds) {
  return ResponseBody.fromString(
    jsonEncode({
      'error': {'code': 'RATE_LIMITED', 'message': 'too many'},
    }),
    429,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
      'retry-after': ['$seconds'],
    },
  );
}

ResponseBody _okJson() {
  return ResponseBody.fromString(
    jsonEncode({'items': <dynamic>[]}),
    200,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );
}
