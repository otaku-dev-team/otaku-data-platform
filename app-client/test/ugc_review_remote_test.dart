import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:otaku_app/features/ugc_review/ugc_review.dart';

/// 点评的远程数据源。
///
/// 钉三处：**端点路径**、**找「我」的方式**、**PATCH 的合并语义**。
/// 第三条最容易写错——契约是「省略 = 沿用原值，`null` = 清空」，
/// 而客户端保存整份表单，所以必须两项都传。
void main() {
  test('概览：打 summary 路径，均分解析成 double?', () async {
    final stub = _Stub(
      body: <String, dynamic>{
        'total': 12,
        'rated': 9,
        'average': 8.3,
        'distribution': <String, dynamic>{'8': 4, '9': 5},
      },
    );

    final summary = await HttpUgcReviewDataSource(
      _dio(stub),
    ).fetchSummary('W-1');

    expect(stub.requests.single.path, '/api/works/W-1/reviews/summary');
    expect(summary.total, 12);
    expect(summary.rated, 9);
    expect(summary.average, closeTo(8.3, 0.001));
    expect(summary.distribution, <int, int>{8: 4, 9: 5});
  });

  test('找「我」：按 author 比对用户名；不在第一页就是 null', () async {
    final stub = _Stub(
      body: <String, dynamic>{
        'page': 1,
        'page_size': 20,
        'total': 40,
        'total_pages': 2,
        'items': <dynamic>[
          _item('R-1', 'alice', 8),
          _item('R-2', 'bob', 9),
        ],
      },
    );

    final source = HttpUgcReviewDataSource(_dio(stub));

    expect((await source.fetchMine('W-1', 'alice'))?.reviewId, 'R-1');
    // 不在第一页 → null（契约缺口 #531，见数据源的注释）。
    expect(await source.fetchMine('W-1', 'carol'), isNull);
  });

  test('发表：POST /api/me/reviews，三个字段都显式传', () async {
    final stub = _Stub(
      statusCode: 201,
      body: _item('R-9', 'alice', 8),
    );

    await HttpUgcReviewDataSource(
      _dio(stub),
    ).create(workId: 'W-1', rating: 8, body: '好看');

    final request = stub.requests.single;
    expect(request.method, 'POST');
    expect(request.path, '/api/me/reviews');
    expect(request.data, <String, dynamic>{
      'work_id': 'W-1',
      'rating': 8,
      'body': '好看',
    });
  });

  test('编辑：PATCH 带 id，null 表示清空（不是「沿用」）', () async {
    final stub = _Stub(body: _item('R-9', 'alice', null));

    await HttpUgcReviewDataSource(
      _dio(stub),
    ).update('R-9', rating: null, body: '只留正文');

    final request = stub.requests.single;
    expect(request.method, 'PATCH');
    expect(request.path, '/api/me/reviews/R-9');
    // 显式 null：契约里「省略」才是沿用原值。
    expect(request.data, <String, dynamic>{
      'rating': null,
      'body': '只留正文',
    });
  });
}

Map<String, dynamic> _item(String id, String author, int? rating) =>
    <String, dynamic>{
      'review_id': id,
      'work_id': 'W-1',
      'author': author,
      'rating': rating,
      'body': null,
      'status': 'published',
      'created_at': '2026-11-07T10:00:00Z',
    };

Dio _dio(Interceptor stub) =>
    Dio(BaseOptions(baseUrl: 'https://example.com'))..interceptors.add(stub);

class _Stub extends Interceptor {
  _Stub({this.statusCode = 200, this.body});

  final int statusCode;
  final Map<String, dynamic>? body;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    requests.add(options);
    handler.resolve(
      Response<Map<String, dynamic>>(
        requestOptions: options,
        statusCode: statusCode,
        data: body,
      ),
    );
  }
}
