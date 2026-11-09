import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/data/models/studio_page.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/features/studio/studio_data_source.dart';
import 'package:otaku_app/features/studio/studio_page.dart';

/// #558 制作公司页。
///
/// 钉的是两件会静默出错的事：**公司名怎么进路径**（大小写/空格/日文都原样，
/// 不能自己归一）、以及 **404 不能被画成空态**（那会让人以为公司存在但没作品）。
void main() {
  group('数据源', () {
    test('公司名整值编码进路径，limit/offset 带对', () async {
      final stub = _Stub(
        body: <String, dynamic>{
          'name': '京都アニメーション',
          'total': 42,
          'items': <dynamic>[_work('w-1', '某部作品')],
        },
      );

      final page = await StudioRemoteDataSource(
        _dio(stub),
      ).fetch('京都アニメーション', limit: 60, offset: 120);

      expect(stub.request.path, contains('/api/studios/'));
      // 空格、日文都要编码进去，而不是被拼成两个路径段。
      expect(stub.request.path, contains(Uri.encodeComponent('京都アニメーション')));
      expect(stub.request.queryParameters['limit'], 60);
      expect(stub.request.queryParameters['offset'], 120);
      expect(page.name, '京都アニメーション');
      expect(page.total, 42);
      expect(page.items.single.workId, 'w-1');
    });

    test('total 与 items 长度无关——头部数字不能拿长度顶', () {
      final page = StudioPage.fromJson(<String, dynamic>{
        'name': 'A-1 Pictures',
        'total': 300,
        'items': <dynamic>[_work('w-1', '一'), _work('w-2', '二')],
      });

      expect(page.total, 300);
      expect(page.items, hasLength(2));
    });

    test('单条坏卡跳过，不毁整页', () {
      final page = StudioPage.fromJson(<String, dynamic>{
        'name': 'X',
        'total': 2,
        'items': <dynamic>[
          <String, dynamic>{'work_id': 'w-1'}, // 缺 title
          _work('w-2', '好的那张'),
        ],
      });

      expect(page.items.map((w) => w.workId), <String>['w-2']);
    });
  });

  group('页面', () {
    testWidgets('渲染公司名、总数与作品卡', (tester) async {
      await tester.pumpWidget(
        _host(
          const _FakeStudioSource(
            StudioPage(
              name: '京都アニメーション',
              total: 42,
              items: <WorkSummary>[
                WorkSummary(workId: 'w-1', workType: WorkType.anime, title: '冰菓'),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('京都アニメーション'), findsWidgets);
      // 头部数字用 total（42），不是 items.length（1）。
      expect(find.textContaining('42 部'), findsOneWidget);
      expect(find.text('冰菓'), findsWidgets);
    });

    testWidgets('404 给「没有找到」，不是空态', (tester) async {
      await tester.pumpWidget(
        _host(const _NotFoundStudioSource()),
      );
      await tester.pumpAndSettle();

      expect(find.text('没有找到这家制作公司'), findsOneWidget);
      // 空态文案不该出现：公司在不在、和有没有作品，是两件事。
      expect(find.textContaining('暂时没有可展示'), findsNothing);
    });
  });
}

Widget _host(StudioDataSource source) {
  final container = ProviderContainer(
    overrides: [studioDataSourceProvider.overrideWithValue(source)],
  );
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      home: StudioPageWidget(name: '京都アニメーション'),
    ),
  );
}

class _FakeStudioSource implements StudioDataSource {
  const _FakeStudioSource(this.page);

  final StudioPage page;

  @override
  Future<StudioPage> fetch(String name, {int limit = 60, int offset = 0}) async =>
      page;
}

class _NotFoundStudioSource implements StudioDataSource {
  const _NotFoundStudioSource();

  @override
  Future<StudioPage> fetch(String name, {int limit = 60, int offset = 0}) async {
    throw const ApiException(
      code: ApiErrorCode.studioNotFound,
      message: '没有找到这家制作公司',
    );
  }
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
