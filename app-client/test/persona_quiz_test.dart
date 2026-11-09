import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:otaku_app/data/datasources/collection_data_source.dart';
import 'package:otaku_app/data/models/collection_entry.dart';
import 'package:otaku_app/data/models/collection_state.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/data/repositories/collection_repository.dart';
import 'package:otaku_app/features/persona/persona_data_source.dart';
import 'package:otaku_app/features/persona/persona_quiz_data_source.dart';
import 'package:otaku_app/features/persona/persona_quiz_page.dart';

/// #505 冷启动补标：题面解析 + 点选后真的写收藏。
///
/// 钉的是**「点了等于记上了」**——按钮点了却没写、或者写错状态，用户补完
/// 一百部才发现画像没变，这是最难自己发现的失败。
void main() {
  group('题面解析', () {
    test('请求 /api/persona/quiz，带 seed 与 size', () async {
      final stub = _Stub(
        body: <String, dynamic>{
          'seed': 7,
          'size': 2,
          'works': <dynamic>[
            _work('w-1', '某部作品'),
            _work('w-2', '另一部'),
          ],
        },
      );

      final paper = await PersonaQuizRemoteDataSource(
        _dio(stub),
      ).fetchPaper(seed: 7, size: 20);

      expect(stub.request.method, 'GET');
      expect(stub.request.path, PersonaQuizRemoteDataSource.path);
      expect(stub.request.queryParameters['seed'], 7);
      expect(stub.request.queryParameters['size'], 20);
      expect(paper.seed, 7);
      expect(paper.size, 2);
      expect(paper.works.map((w) => w.workId), <String>['w-1', 'w-2']);
    });

    test('size 按实际条数算——否则坏卡被跳过后最后一张会越界', () async {
      final stub = _Stub(
        body: <String, dynamic>{
          'seed': 0,
          'size': 20, // 服务端声称 20，但只给了 1 部
          'works': <dynamic>[_work('w-1', '只剩一部')],
        },
      );

      final paper = await PersonaQuizRemoteDataSource(
        _dio(stub),
      ).fetchPaper(seed: 0, size: 20);

      expect(
        paper.size,
        1,
        reason: '按 20 判断「没做完」会去取 works[1]，直接越界崩',
      );
    });

    test('单条坏卡不毁整份题面', () async {
      final stub = _Stub(
        body: <String, dynamic>{
          'seed': 0,
          'size': 2,
          'works': <dynamic>[
            <String, dynamic>{'work_id': 'w-1'}, // 缺 title → 解析失败
            _work('w-2', '好的那张'),
          ],
        },
      );

      final paper = await PersonaQuizRemoteDataSource(
        _dio(stub),
      ).fetchPaper(seed: 0, size: 20);

      expect(paper.works.map((w) => w.workId), <String>['w-2']);
      // 服务端写 2，但坏卡被跳过 → 实际只有 1 题，进度条也必须按 1 算。
      expect(paper.size, 1);
    });
  });

  group('点选页', () {
    testWidgets('点「看过」写 watched 并前进；标完给完成态', (tester) async {
      final collection = _RecordingCollectionDataSource();
      await tester.pumpWidget(
        _host(
          paper: const QuizPaper(
            seed: 0,
            size: 2,
            works: <WorkSummary>[
              WorkSummary(workId: 'w-1', workType: WorkType.anime, title: '第一部'),
              WorkSummary(workId: 'w-2', workType: WorkType.anime, title: '第二部'),
            ],
          ),
          collection: collection,
        ),
      );
      await tester.pumpAndSettle();

      // 封面占位也会显示标题，所以是 findsWidgets 而不是 One。
      expect(find.text('第一部'), findsWidgets);
      expect(find.text('0 / 2'), findsOneWidget);

      await tester.tap(find.text('看过'));
      await tester.pumpAndSettle();

      // 写了、且写的是 watched（不是「看过」这个中文串）。
      expect(collection.added, hasLength(1));
      expect(collection.added.single.$1, 'w-1');
      expect(collection.added.single.$2, CollectionStatus.watched);
      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.text('第二部'), findsWidgets);

      await tester.tap(find.text('抛弃'));
      await tester.pumpAndSettle();

      expect(collection.added.last.$2, CollectionStatus.dropped);
      expect(find.text('这一批标完了'), findsOneWidget);
      expect(find.textContaining('2 部'), findsOneWidget);
    });

    testWidgets('写失败不前进——没记上却跳走等于骗用户', (tester) async {
      final collection = _RecordingCollectionDataSource(fail: true);
      await tester.pumpWidget(
        _host(
          paper: const QuizPaper(
            seed: 0,
            size: 1,
            works: <WorkSummary>[
              WorkSummary(workId: 'w-1', workType: WorkType.anime, title: '第一部'),
            ],
          ),
          collection: collection,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('看过'));
      await tester.pumpAndSettle();

      expect(collection.added, hasLength(1));
      expect(find.text('0 / 1'), findsOneWidget, reason: '失败后应停在原地');
      expect(find.textContaining('没记上'), findsOneWidget);
    });

    testWidgets('未登录：不进题面，直接说明', (tester) async {
      await tester.pumpWidget(
        _host(
          paper: const QuizPaper(seed: 0, size: 1, works: <WorkSummary>[]),
          collection: _RecordingCollectionDataSource(),
          signedIn: false,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('登录后才能补标。'), findsOneWidget);
      expect(find.text('0 / 1'), findsNothing);
    });
  });
}

Widget _host({
  required QuizPaper paper,
  required CollectionDataSource collection,
  bool signedIn = true,
}) {
  final container = ProviderContainer(
    overrides: [
      personaQuizDataSourceProvider.overrideWithValue(_FixedQuizSource(paper)),
      collectionDataSourceProvider.overrideWithValue(collection),
      personalizedAudienceProvider.overrideWithValue(signedIn),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: PersonaQuizPage()),
  );
}

class _FixedQuizSource implements PersonaQuizDataSource {
  const _FixedQuizSource(this.paper);

  final QuizPaper paper;

  @override
  Future<QuizPaper> fetchPaper({required int seed, required int size}) async =>
      paper;
}

class _RecordingCollectionDataSource implements CollectionDataSource {
  _RecordingCollectionDataSource({this.fail = false});

  final bool fail;
  final List<(String, CollectionStatus?)> added = <(String, CollectionStatus?)>[];

  @override
  Future<List<CollectionEntry>> fetchAll({CollectionStatus? status}) async =>
      const <CollectionEntry>[];

  @override
  Future<CollectionState> add(String workId, {CollectionStatus? status}) async {
    added.add((workId, status));
    if (fail) throw StateError('boom');
    return CollectionState(workId: workId, collected: true, status: status);
  }

  @override
  Future<CollectionState> fetchState(String workId) async =>
      CollectionState(workId: workId, collected: false);

  @override
  Future<CollectionState> updateStatus(
    String workId,
    CollectionStatus? status,
  ) async => CollectionState(workId: workId, collected: true, status: status);

  @override
  Future<void> remove(String workId) async {}
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
