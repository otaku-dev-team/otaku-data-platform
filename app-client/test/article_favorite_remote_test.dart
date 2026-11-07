import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/features/article_favorite/article_favorite_data_source.dart';

/// 资讯收藏的远程数据源（`/api/me/article-favorites`）。
///
/// 钉「写错了会静默失败」的三处：路径、方法、`article_id` 的编码。
/// 契约里 `PUT`/`DELETE` 都幂等，所以客户端不需要先查状态再写——
/// 这条如果写反（先 GET 再写），多一次往返还是小事，状态竞态才是麻烦。
void main() {
  test('列表：路径与分页参数，item 映射成 Entry', () async {
    final stub = _Stub(
      body: <String, dynamic>{
        'page': 2,
        'page_size': 20,
        'total': 41,
        'total_pages': 3,
        'items': <dynamic>[
          <String, dynamic>{
            'article': <String, dynamic>{
              'article_id': 'A-1',
              'title': '标题一',
            },
            'favorited_at': '2026-11-07T10:00:00Z',
          },
        ],
      },
    );

    final page = await ArticleFavoriteRemoteDataSource(
      _dio(stub),
    ).fetchPage(page: 2, pageSize: 20);

    final request = stub.requests.single;
    expect(request.method, 'GET');
    expect(request.path, '/api/me/article-favorites');
    expect(request.queryParameters, <String, dynamic>{
      'page': 2,
      'page_size': 20,
    });

    expect(page.items.single.article.articleId, 'A-1');
    expect(page.totalPages, 3);
    expect(page.items.single.favoritedAt, isNotNull);
  });

  test('单条状态：未收藏是 200 + false，不抛异常', () async {
    final stub = _Stub(
      body: <String, dynamic>{'article_id': 'A-1', 'favorited': false},
    );

    final favorited = await ArticleFavoriteRemoteDataSource(
      _dio(stub),
    ).isFavorited('A-1');

    expect(favorited, isFalse);
  });

  test('收藏 / 取消：PUT 与 DELETE 打同一个单条路径，id 整值编码', () async {
    final stub = _Stub(statusCode: 204);
    final source = ArticleFavoriteRemoteDataSource(_dio(stub));

    await source.favorite('A/1');
    await source.unfavorite('A/1');

    expect(stub.requests[0].method, 'PUT');
    expect(stub.requests[1].method, 'DELETE');
    // 带斜杠的 id 不会被拼成两段路径。
    expect(stub.requests[0].path, '/api/me/article-favorites/A%2F1');
    expect(stub.requests[1].path, '/api/me/article-favorites/A%2F1');
  });

  test('200 但空响应体：抛错，不当成空列表', () async {
    final stub = _Stub();

    expect(
      () => ArticleFavoriteRemoteDataSource(_dio(stub)).fetchPage(),
      throwsA(isA<ApiException>()),
    );
  });
}

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
