import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:otaku_app/features/detail/view_report.dart';

/// 作品浏览打点（`POST /api/me/views`）。
///
/// 契约说「重复提交正常、不需要回执、失败可静默」——前三项都由服务端保证，
/// 客户端只负责**打对端点与请求体**。这一条尤其要钉：路径打错会 404，而 404
/// 又被 `report` 静默吞掉，结果是上报表永远空、还没有任何报错。
void main() {
  test('打对端点与请求体，且只带 work_id（时间以服务端收到为准）', () async {
    final stub = _Stub();
    await HttpViewReporter(_dio(stub)).report('W-abc123');

    final request = stub.requests.single;
    expect(request.method, 'POST');
    expect(request.path, '/api/me/views');
    expect(request.data, <String, dynamic>{'work_id': 'W-abc123'});
  });

  test('服务端 5xx 也不抛：打点失败不该影响详情页', () async {
    final stub = _Stub(statusCode: 500);

    // 不抛异常即为通过——`report` 的语义就是「永远不抛」。
    await HttpViewReporter(_dio(stub)).report('W-abc123');
  });

  test('网络异常同样吞掉', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.com'))
      ..interceptors.add(_ThrowingStub());

    await HttpViewReporter(dio).report('W-abc123');
  });
}

Dio _dio(Interceptor stub) =>
    Dio(BaseOptions(baseUrl: 'https://example.com'))..interceptors.add(stub);

class _Stub extends Interceptor {
  _Stub({this.statusCode = 204});

  final int statusCode;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    requests.add(options);
    handler.resolve(
      Response<void>(requestOptions: options, statusCode: statusCode),
    );
  }
}

class _ThrowingStub extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    handler.reject(DioException(requestOptions: options, message: 'boom'));
  }
}
