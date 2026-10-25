import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/app.dart';
import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/data/datasources/collection_data_source.dart';
import 'package:otaku_app/data/datasources/collection_mock_data_source.dart';
import 'package:otaku_app/data/datasources/work_data_source.dart';
import 'package:otaku_app/data/models/collection_entry.dart';
import 'package:otaku_app/data/models/collection_state.dart';
import 'package:otaku_app/data/models/paged_result.dart';
import 'package:otaku_app/data/models/related_works.dart';
import 'package:otaku_app/data/models/work.dart';
import 'package:otaku_app/data/models/work_sort.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/data/repositories/collection_repository.dart';
import 'package:otaku_app/data/repositories/work_repository.dart';
import 'package:otaku_app/features/auth/auth_controller.dart';
import 'package:otaku_app/features/collection/collection_controller.dart';
import 'package:otaku_app/features/contents/work_card.dart';
import 'package:otaku_app/features/detail/work_collection_controller.dart';
import 'package:otaku_app/features/detail/work_detail_page.dart';
import 'package:otaku_app/core/router/app_router.dart';
import 'package:otaku_app/core/router/route_paths.dart';

import 'support/test_overrides.dart';

Work _work(String workId) =>
    Work(workId: workId, workType: WorkType.anime, title: '测试作品 $workId');

/// 只为详情页提供一部作品，列表接口用不到。
class _FakeWorkSource implements WorkDataSource {
  @override
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    WorkSort sort = WorkSort.id,
    int page = 1,
    int pageSize = 20,
    String? tag,
  }) async {
    return PagedResult<WorkSummary>(
      items: [
        WorkSummary(workId: 'W-1', workType: WorkType.anime, title: '测试作品 W-1'),
      ],
      total: 1,
      page: 1,
      pageSize: pageSize,
      totalPages: 1,
    );
  }

  @override
  Future<Work> fetchDetail(String workId) async => _work(workId);

  @override
  Future<RelatedWorks> fetchRelated(String workId, {int limit = 6}) async =>
      const RelatedWorks(basisTags: <String>[], items: <WorkSummary>[]);
}

/// 在 Mock 收藏源上加计数器：既保留契约语义（upsert / 只改不建 / 幂等删除），
/// 又能断言「该发的请求发了、不该发的一条没发」。
class _CountingCollectionSource extends CollectionMockDataSource {
  _CountingCollectionSource() : super(delay: Duration.zero);

  int stateCalls = 0;
  int listCalls = 0;
  int addCalls = 0;

  @override
  Future<CollectionState> fetchState(String workId) {
    stateCalls++;
    return super.fetchState(workId);
  }

  @override
  Future<List<CollectionEntry>> fetchAll({CollectionStatus? status}) {
    listCalls++;
    return super.fetchAll(status: status);
  }

  @override
  Future<CollectionState> add(String workId, {CollectionStatus? status}) {
    addCalls++;
    return super.add(workId, status: status);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer createContainer({
    String? token,
    CollectionDataSource? collection,
  }) {
    final container = ProviderContainer(
      overrides: [
        ...authOverrides(token: token),
        collectionDataSourceProvider.overrideWithValue(
          collection ?? _CountingCollectionSource(),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// `AuthController.build` 用微任务恢复会话，等它跑完再读其他 provider。
  Future<void> settleAuth(ProviderContainer container) async {
    container.read(authControllerProvider);
    for (var i = 0; i < 50; i++) {
      if (container.read(authControllerProvider).status !=
          AuthStatus.checking) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  group('WorkCollectionController', () {
    test('未登录：不发状态查询，按「未收藏」处理', () async {
      final source = _CountingCollectionSource();
      final container = createContainer(collection: source);
      await settleAuth(container);

      final sub = container.listen(workCollectionProvider('W-1'), (_, _) {});
      addTearDown(sub.close);

      final state = await container.read(workCollectionProvider('W-1').future);
      expect(state.collected, isFalse);
      // 未登录的请求必然 401，客户端不该把它当正常路径跑一遍。
      expect(source.stateCalls, 0);
    });

    test('已登录：首查一次，toggle 在收藏与取消之间来回切', () async {
      final source = _CountingCollectionSource();
      final container = createContainer(
        token: signedInToken,
        collection: source,
      );
      await settleAuth(container);

      final sub = container.listen(workCollectionProvider('W-1'), (_, _) {});
      addTearDown(sub.close);

      final initial = await container.read(
        workCollectionProvider('W-1').future,
      );
      expect(initial.collected, isFalse);
      expect(source.stateCalls, 1);

      final notifier = container.read(workCollectionProvider('W-1').notifier);
      expect(await notifier.toggle(_work('W-1')), isNull);
      expect(source.addCalls, 1);
      expect(
        container.read(workCollectionProvider('W-1')).requireValue.collected,
        isTrue,
      );

      expect(await notifier.toggle(_work('W-1')), isNull);
      expect(
        container.read(workCollectionProvider('W-1')).requireValue.collected,
        isFalse,
      );
    });

    test('collect 幂等：已收藏时不再发 PUT，避免把已有状态覆盖成空', () async {
      final source = _CountingCollectionSource();
      final container = createContainer(
        token: signedInToken,
        collection: source,
      );
      await settleAuth(container);

      final sub = container.listen(
        workCollectionProvider('mock-w-001'),
        (_, _) {},
      );
      addTearDown(sub.close);

      final initial = await container.read(
        workCollectionProvider('mock-w-001').future,
      );
      expect(initial.collected, isTrue);
      expect(initial.status, CollectionStatus.watching);

      final error = await container
          .read(workCollectionProvider('mock-w-001').notifier)
          .collect(_work('mock-w-001'));
      expect(error, isNull);
      expect(source.addCalls, 0);
    });

    test('对未收藏的作品改状态：返回 COLLECTION_REQUIRED，不静默补收藏', () async {
      final container = createContainer(token: signedInToken);
      await settleAuth(container);

      final sub = container.listen(workCollectionProvider('W-1'), (_, _) {});
      addTearDown(sub.close);
      await container.read(workCollectionProvider('W-1').future);

      final error = await container
          .read(workCollectionProvider('W-1').notifier)
          .setStatus(CollectionStatus.watching);

      // C11：PATCH 只改不建，客户端不能收到 409 后再补一个 PUT。
      expect(error?.code, ApiErrorCode.collectionRequired);
      final after = await container.read(workCollectionProvider('W-1').future);
      expect(after.collected, isFalse);
    });

    test('详情页收藏后，收藏页的列表缓存随之失效并重新拉取', () async {
      final source = _CountingCollectionSource();
      final container = createContainer(
        token: signedInToken,
        collection: source,
      );
      await settleAuth(container);

      final listSub = container.listen(collectionControllerProvider, (_, _) {});
      addTearDown(listSub.close);
      final detailSub = container.listen(
        workCollectionProvider('W-9'),
        (_, _) {},
      );
      addTearDown(detailSub.close);

      final before = await container.read(collectionControllerProvider.future);
      expect(before.value.any((entry) => entry.workId == 'W-9'), isFalse);

      await container
          .read(workCollectionProvider('W-9').notifier)
          .toggle(_work('W-9'));

      final after = await container.read(collectionControllerProvider.future);
      expect(after.value.any((entry) => entry.workId == 'W-9'), isTrue);
    });
  });

  group('详情页收藏区', () {
    Widget app({String? token, String workId = 'W-1'}) {
      return ProviderScope(
        overrides: [
          ...authOverrides(token: token),
          workDataSourceProvider.overrideWithValue(_FakeWorkSource()),
          collectionDataSourceProvider.overrideWithValue(
            CollectionMockDataSource(delay: Duration.zero),
          ),
        ],
        child: MaterialApp(home: WorkDetailPage(workId: workId)),
      );
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('未登录：显示「登录后收藏」，不显示收藏按钮', (tester) async {
      await tester.pumpWidget(app());
      await settle(tester);

      expect(find.text('登录后收藏'), findsOneWidget);
      expect(find.text('收藏'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('已登录未收藏：点「收藏」后变「已收藏」并出现状态选择器', (tester) async {
      await tester.pumpWidget(app(token: signedInToken));
      await settle(tester);

      expect(find.text('收藏'), findsOneWidget);
      expect(find.text('未设状态'), findsNothing);

      await tester.tap(find.text('收藏'));
      await settle(tester);

      expect(find.text('已收藏'), findsOneWidget);
      // 状态默认是 null（收藏但未设状态），选择器按钮以「未设状态」呈现。
      expect(find.text('未设状态'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('已收藏的作品：按钮直接是「已收藏」，并显示服务端给的状态', (tester) async {
      await tester.pumpWidget(app(token: signedInToken, workId: 'mock-w-001'));
      await settle(tester);

      expect(find.text('已收藏'), findsOneWidget);
      expect(find.text('在看'), findsOneWidget);
    });

    testWidgets('未登录点「登录后收藏」：登录成功回到详情页，作品已在收藏里', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appInitialLocationProvider.overrideWithValue(RoutePaths.contents),
            ...authOverrides(),
            workDataSourceProvider.overrideWithValue(_FakeWorkSource()),
            collectionDataSourceProvider.overrideWithValue(
              CollectionMockDataSource(delay: Duration.zero),
            ),
          ],
          child: const OtakuApp(),
        ),
      );
      await settle(tester);

      await tester.tap(find.byType(WorkCard).first);
      await settle(tester);
      expect(find.text('登录后收藏'), findsOneWidget);

      await tester.tap(find.text('登录后收藏'));
      await settle(tester);

      // 登录页默认只露出站点授权主按钮，平台账号表单要先展开
      //（双入口方案：主路径是授权，表单是次级）。
      await tester.tap(find.text('使用平台账号登录'));
      await settle(tester);

      // 登录页：两个输入框 + 提交按钮。
      await tester.enterText(find.byType(TextField).at(0), 'alice');
      await tester.enterText(find.byType(TextField).at(1), 'secret');
      await tester.tap(find.widgetWithText(FilledButton, '登录'));
      await settle(tester);

      // 登录成功后自动 pop 回详情页，并把刚才想收藏的作品收进去。
      expect(find.text('已收藏'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
