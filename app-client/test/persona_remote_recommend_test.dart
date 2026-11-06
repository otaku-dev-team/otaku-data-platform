import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/features/persona/persona_data_source.dart';
import 'package:otaku_app/features/persona/personalized_recommend_section.dart';

/// #376 推荐位接真数据的回归测试。
///
/// 钉的都是「接口上线后才会暴露」的事：`/api/me/recommend` 的路径与参数、
/// `cold_start` 改标题、规则 key → 理由文案、游客不请求（否则 401 会踢会话）、
/// 以及坏条目不能让整块推荐消失。不连真站，全部走 Dio 拦截器桩。
void main() {
  test('登录用户：请求 /api/me/recommend?limit=20，work 与 reasons 映射成展示模型', () async {
    final stub = _Stub(
      (options) => _ok(options, _page(
        items: <dynamic>[
          _item(
            _work('w-1', '银河边缘的旧书店'),
            reasons: <dynamic>[
              _reason('tag', '科幻', 1.0),
              _reason('type', 'anime', 0.4),
              // 负权重是「不喜欢」的证据，不能显示成推荐理由。
              _reason('tag', '后宫', -0.6),
            ],
          ),
          _item(
            _work('w-2', '雨夜考据部'),
            reasons: <dynamic>[_reason('tag', '群像', 0.8)],
          ),
        ],
      )),
    );
    final feed = await PersonaRemoteDataSource(_dio(stub)).fetchFeed(signedIn: true);

    expect(stub.requests, hasLength(1));
    expect(stub.requests.single.method, 'GET');
    expect(stub.requests.single.path, PersonaRemoteDataSource.recommendPath);
    expect(stub.requests.single.queryParameters['limit'], 20);

    expect(feed.isGuest, isFalse);
    expect(feed.coldStart, isFalse);
    expect(feed.items, hasLength(2));
    expect(feed.items.first.work.workId, 'w-1');
    expect(feed.items.first.work.title, '银河边缘的旧书店');
    expect(feed.items.first.reasons, <String>['你偏爱的「科幻」', '你常看的动画']);
    expect(feed.items.last.reasons, <String>['你偏爱的「群像」']);
  });

  test('cold_start = true：透传标记，冷启动项目不带理由', () async {
    final stub = _Stub(
      (options) => _ok(options, _page(
        coldStart: true,
        items: <dynamic>[_item(_work('w-9', '全站高分第一'), reasons: <dynamic>[])],
      )),
    );
    final feed = await PersonaRemoteDataSource(_dio(stub)).fetchFeed(signedIn: true);

    expect(feed.coldStart, isTrue);
    expect(feed.items.single.reasons, isEmpty);
  });

  test('游客：一个请求都不发，回落引导卡', () async {
    final stub = _Stub((options) => _ok(options, _page(items: <dynamic>[])));
    final feed = await PersonaRemoteDataSource(_dio(stub)).fetchFeed(signedIn: false);

    expect(stub.requests, isEmpty);
    expect(feed.isGuest, isTrue);
    expect(feed.items, isEmpty);
    expect(feed.coldStart, isFalse);
  });

  test('坏条目跳过，其余照常展示', () async {
    final stub = _Stub(
      (options) => _ok(options, _page(items: <dynamic>[
        // work_id 缺失：WorkSummary.fromJson 会抛 FormatException。
        _item(<String, dynamic>{'work_type': 'anime', 'title': '缺 id'}),
        // work 根本不是对象。
        <String, dynamic>{'work': 'oops', 'score': 0, 'reasons': <dynamic>[]},
        _item(_work('w-3', '完好条目')),
      ])),
    );
    final feed = await PersonaRemoteDataSource(_dio(stub)).fetchFeed(signedIn: true);

    expect(feed.items, hasLength(1));
    expect(feed.items.single.work.workId, 'w-3');
  });

  test('空响应抛 ApiException，不伪装成空列表', () async {
    final stub = _Stub((options) => _ok(options, null));

    await expectLater(
      PersonaRemoteDataSource(_dio(stub)).fetchFeed(signedIn: true),
      throwsA(isA<ApiException>()),
    );
  });

  test('画像页仍取演示数据（#375 不在本轮）', () async {
    final stub = _Stub((options) => _ok(options, _page(items: <dynamic>[])));
    final insight = await PersonaRemoteDataSource(_dio(stub)).fetchInsight();

    expect(insight.title, '深夜考据派');
    expect(stub.requests, isEmpty);
  });

  testWidgets('正常结果：标题「为你推荐」+「按画像」，理由可见', (tester) async {
    final stub = _Stub(
      (options) => _ok(options, _page(items: <dynamic>[
        _item(
          _work('w-1', '银河边缘的旧书店'),
          reasons: <dynamic>[_reason('tag', '科幻', 1.0)],
        ),
      ])),
    );
    await tester.pumpWidget(host(_dio(stub)));
    await tester.pumpAndSettle();

    expect(find.text('为你推荐'), findsOneWidget);
    expect(find.text('按画像'), findsOneWidget);
    expect(find.text('热门推荐'), findsNothing);
    expect(find.text('银河边缘的旧书店'), findsOneWidget);
    expect(find.text('你偏爱的「科幻」'), findsOneWidget);
  });

  testWidgets('冷启动：标题改「热门推荐」，不冒充个性化结果', (tester) async {
    final stub = _Stub(
      (options) => _ok(options, _page(
        coldStart: true,
        items: <dynamic>[_item(_work('w-9', '全站高分第一'))],
      )),
    );
    await tester.pumpWidget(host(_dio(stub)));
    await tester.pumpAndSettle();

    expect(find.text('热门推荐'), findsOneWidget);
    expect(find.text('全站高分'), findsOneWidget);
    expect(find.text('为你推荐'), findsNothing);
    expect(find.text('全站高分第一'), findsOneWidget);
  });

  testWidgets('游客态 UI：引导卡且不触发任何请求', (tester) async {
    final stub = _Stub((options) => _ok(options, _page(items: <dynamic>[])));
    await tester.pumpWidget(host(_dio(stub), signedIn: false));
    await tester.pumpAndSettle();

    expect(stub.requests, isEmpty);
    expect(find.textContaining('登录后'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
  });

  testWidgets('服务端失败：区块内错误态 + 重试', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'))
      ..interceptors.add(_RejectStub());
    await tester.pumpWidget(host(dio));
    await tester.pumpAndSettle();

    expect(find.text('暂时取不到数据'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });
}

Widget host(Dio dio, {bool signedIn = true}) {
  final container = ProviderContainer(
    overrides: [
      personaDataSourceProvider.overrideWithValue(PersonaRemoteDataSource(dio)),
      personalizedAudienceProvider.overrideWithValue(signedIn),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: PersonalizedRecommendSection()),
      ),
    ),
  );
}

Dio _dio(_Stub stub) =>
    Dio(BaseOptions(baseUrl: 'http://test'))..interceptors.add(stub);

class _Stub extends Interceptor {
  _Stub(this._respond);

  final Response<Map<String, dynamic>> Function(RequestOptions) _respond;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    requests.add(options);
    handler.resolve(_respond(options));
  }
}

class _RejectStub extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    handler.reject(
      DioException(
        requestOptions: options,
        type: DioExceptionType.badResponse,
        response: Response<dynamic>(requestOptions: options, statusCode: 500),
      ),
    );
  }
}

Response<Map<String, dynamic>> _ok(
  RequestOptions options,
  Map<String, dynamic>? data,
) => Response<Map<String, dynamic>>(
  requestOptions: options,
  statusCode: 200,
  data: data,
);

Map<String, dynamic> _page({
  List<dynamic> items = const <dynamic>[],
  bool coldStart = false,
}) => <String, dynamic>{
  'items': items,
  'cold_start': coldStart,
  'generated_at': '2026-11-06T18:00:00Z',
};

Map<String, dynamic> _item(
  Map<String, dynamic> work, {
  List<dynamic> reasons = const <dynamic>[],
  double score = 0.8,
}) => <String, dynamic>{
  'work': work,
  'score': score,
  'reasons': reasons,
};

Map<String, dynamic> _work(String id, String title) => <String, dynamic>{
  'work_id': id,
  'work_type': 'anime',
  'title': title,
  'release_year': 2024,
  'cover_url': null,
  'tags': <String>['科幻'],
  'main_rating': null,
  'source': 'bangumi',
};

Map<String, dynamic> _reason(String type, String value, num weight) =>
    <String, dynamic>{'type': type, 'value': value, 'weight': weight};
