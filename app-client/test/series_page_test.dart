import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/core/router/route_paths.dart';
import 'package:otaku_app/data/models/series_page.dart';
import 'package:otaku_app/data/models/work_series.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/features/series/series_data_source.dart';
import 'package:otaku_app/features/series/series_page.dart';

/// #557 / #568 P2 系列页。
///
/// 钉四件会静默出错的事：key 整值编码、`total` 用服务端字段而不是卡片数、
/// `name` 为 null 时不拿 key 当标题、404 不是空态。
void main() {
  group('路由与数据源', () {
    test('系列 key 整值编码，limit/offset 带对', () async {
      final stub = _Stub(
        body: <String, dynamic>{
          'key': '154',
          'name': '机动战士高达',
          'total': 16,
          'items': <dynamic>[_work('w-1', '某部作品')],
        },
      );

      final page = await SeriesRemoteDataSource(
        _dio(stub),
      ).fetchPage('154', limit: 60, offset: 120);

      expect(stub.request.path, '/api/series/154');
      expect(stub.request.queryParameters['limit'], 60);
      expect(stub.request.queryParameters['offset'], 120);
      expect(page.name, '机动战士高达');
      expect(page.total, 16);
      expect(page.items.single.workId, 'w-1');
    });

    test('work_id 整值编码进 /series 路径', () async {
      final stub = _Stub(
        body: <String, dynamic>{
          'series_key': null,
          'series_name': null,
          'items': <dynamic>[],
        },
      );
      await SeriesRemoteDataSource(_dio(stub)).fetchForWork('W-a/b');

      expect(
        stub.request.path,
        '/api/works/${Uri.encodeComponent('W-a/b')}/series',
      );
    });

    test('RoutePaths.seriesPage 是插值不是字面量', () {
      expect(RoutePaths.seriesPage('154'), '/series/154');
      expect(RoutePaths.seriesPage('a/b'), '/series/a%2Fb');
    });

    test('total 与 items 长度无关；name 缺失时为 null', () {
      final page = SeriesPage.fromJson(<String, dynamic>{
        'key': '4281',
        'total': 300,
        'items': <dynamic>[_work('w-1', '一'), _work('w-2', '二')],
      });

      expect(page.total, 300);
      expect(page.name, isNull);
      expect(page.items, hasLength(2));
    });

    test('单条坏卡跳过，不毁整页', () {
      final page = SeriesPage.fromJson(<String, dynamic>{
        'key': '4281',
        'total': 2,
        'items': <dynamic>[
          <String, dynamic>{'work_id': 'w-1'},
          _work('w-2', '好的那张'),
        ],
      });

      expect(page.items.map((w) => w.workId), <String>['w-2']);
    });
  });

  group('页面', () {
    testWidgets('渲染系列名、总数与作品卡', (tester) async {
      await tester.pumpWidget(
        _host(
          _FakeSeriesSource(
            SeriesPage(
              key: '154',
              name: '机动战士高达',
              total: 42,
              items: <WorkSummary>[
                WorkSummary(
                  workId: 'w-1',
                  workType: WorkType.anime,
                  title: '机动战士高达',
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('42 部'), findsOneWidget);
      expect(find.text('机动战士高达'), findsWidgets);
    });

    testWidgets('name 为 null 时退化成「系列」，不拿 key 当标题', (tester) async {
      await tester.pumpWidget(
        _host(
          _FakeSeriesSource(
            SeriesPage(
              key: '154',
              total: 1,
              items: <WorkSummary>[
                WorkSummary(
                  workId: 'w-1',
                  workType: WorkType.anime,
                  title: '某部作品',
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('系列'), findsOneWidget);
      // key 是来源站内部 id，绝不能出现在标题里。
      expect(find.text('154'), findsNothing);
    });

    testWidgets('404 给「没有找到」，不是空态', (tester) async {
      await tester.pumpWidget(_host(const _NotFoundSeriesSource()));
      await tester.pumpAndSettle();

      expect(find.text('没有找到这个系列'), findsOneWidget);
      expect(find.textContaining('暂时没有可展示'), findsNothing);
    });
  });
}

Widget _host(SeriesDataSource source) {
  final container = ProviderContainer(
    overrides: [seriesDataSourceProvider.overrideWithValue(source)],
  );
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      home: SeriesPageWidget(seriesKey: '154'),
    ),
  );
}

class _FakeSeriesSource implements SeriesDataSource {
  const _FakeSeriesSource(this.page);

  final SeriesPage page;

  @override
  Future<SeriesPage> fetchPage(
    String key, {
    int limit = 60,
    int offset = 0,
  }) async =>
      page;

  @override
  Future<WorkSeries> fetchForWork(String workId) async =>
      const WorkSeries(items: <WorkSeriesItem>[]);
}

class _NotFoundSeriesSource implements SeriesDataSource {
  const _NotFoundSeriesSource();

  @override
  Future<SeriesPage> fetchPage(
    String key, {
    int limit = 60,
    int offset = 0,
  }) async {
    throw const ApiException(
      code: ApiErrorCode.seriesNotFound,
      message: '系列不存在',
      statusCode: 404,
    );
  }

  @override
  Future<WorkSeries> fetchForWork(String workId) async =>
      const WorkSeries(items: <WorkSeriesItem>[]);
}

Map<String, dynamic> _work(String id, String title) => <String, dynamic>{
  'work_id': id,
  'work_type': 'anime',
  'title': title,
  'cover_url': null,
  'tags': <String>['科幻'],
  'main_rating': null,
  'source': 'shell',
};

class _Stub {
  _Stub({required this.body});

  final Map<String, dynamic> body;
  late RequestOptions request;

  void handle(RequestOptions options, RequestInterceptorHandler handler) {
    request = options;
    handler.resolve(
      Response<Map<String, dynamic>>(
        requestOptions: options,
        statusCode: 200,
        data: body,
      ),
    );
  }
}

Dio _dio(_Stub stub) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test.local'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => stub.handle(options, handler),
    ),
  );
  return dio;
}
