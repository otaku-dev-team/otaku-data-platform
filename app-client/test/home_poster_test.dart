import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/features/home/home_poster_coverflow.dart';
import 'package:otaku_app/features/home/home_poster_data_source.dart';

/// #562 首页海报 Coverflow。
///
/// 钉两条会静默出错的：**端点路径**（错了 hero 会永远空着，还不报错）
/// 和 **0 条时整块隐藏**（留一块空白比没有 hero 更难看）。
void main() {
  test('请求 /api/home/posters；坏卡跳过不毁整块', () async {
    final stub = _Stub(
      body: <String, dynamic>{
        'items': <dynamic>[
          <String, dynamic>{'work_id': 'w-0'}, // 缺 title
          _work('w-1', '银河边缘的旧书店'),
        ],
      },
    );

    final items = await HomePosterRemoteDataSource(_dio(stub)).fetch();

    expect(stub.request.path, '/api/home/posters');
    expect(items.map((w) => w.workId), <String>['w-1']);
  });

  testWidgets('0 条：整块隐藏，不占首屏', (tester) async {
    await tester.pumpWidget(
      _host(const _FixedSource(<WorkSummary>[])),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PageView), findsNothing);
  });

  testWidgets('有数据：渲染 Coverflow，首张可见', (tester) async {
    await tester.pumpWidget(
      _host(
        const _FixedSource(<WorkSummary>[
          WorkSummary(workId: 'w-1', workType: WorkType.anime, title: '银河边缘的旧书店'),
          WorkSummary(workId: 'w-2', workType: WorkType.anime, title: '雨夜考据部'),
          WorkSummary(workId: 'w-3', workType: WorkType.anime, title: '机战少女的黄昏'),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PageView), findsOneWidget);
    expect(find.text('银河边缘的旧书店'), findsWidgets);
  });
}

Widget _host(HomePosterDataSource source) {
  final container = ProviderContainer(
    overrides: [homePosterDataSourceProvider.overrideWithValue(source)],
  );
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: Scaffold(body: HomePosterCoverflow())),
  );
}

class _FixedSource implements HomePosterDataSource {
  const _FixedSource(this.items);

  final List<WorkSummary> items;

  @override
  Future<List<WorkSummary>> fetch() async => items;
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
