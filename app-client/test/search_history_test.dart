import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/app.dart';
import 'package:otaku_app/core/router/app_router.dart';
import 'package:otaku_app/core/router/route_paths.dart';
import 'package:otaku_app/core/storage/local_prefs.dart';
import 'package:otaku_app/core/storage/local_prefs_provider.dart';
import 'package:otaku_app/core/storage/memory_local_prefs.dart';
import 'package:otaku_app/data/datasources/work_data_source.dart';
import 'package:otaku_app/data/models/paged_result.dart';
import 'package:otaku_app/data/models/related_works.dart';
import 'package:otaku_app/data/models/work.dart';
import 'package:otaku_app/data/models/work_sort.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/data/repositories/work_repository.dart';
import 'package:otaku_app/features/auth/auth_controller.dart';
import 'package:otaku_app/features/contents/contents_controller.dart';
import 'package:otaku_app/features/contents/search_history_controller.dart';

import 'support/test_overrides.dart';

/// 列表页只要有一个能渲染的条目就够：这里测的是搜索框上方那条历史。
class _FakeWorkSource implements WorkDataSource {
  static const summary = WorkSummary(
    workId: 'W-1',
    workType: WorkType.anime,
    title: '进击的巨人',
  );

  @override
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    WorkSort sort = WorkSort.id,
    int page = 1,
    int pageSize = 20,
    List<String>? tags,
  
    int? year,}) async {
    return PagedResult<WorkSummary>(
      items: const [summary],
      total: 1,
      page: 1,
      pageSize: pageSize,
      totalPages: 1,
    );
  }

  @override
  Future<Work> fetchDetail(String workId) async =>
      const Work(workId: 'W-1', workType: WorkType.anime, title: '进击的巨人');

  @override
  Future<RelatedWorks> fetchRelated(String workId, {int limit = 6}) async =>
      const RelatedWorks(basisTags: <String>[], items: <WorkSummary>[]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer createContainer({
    InMemoryLocalPrefs? prefs,
    String? token,
    bool withDataSource = false,
  }) {
    final container = ProviderContainer(
      overrides: [
        localPrefsProvider.overrideWithValue(prefs ?? InMemoryLocalPrefs()),
        ...authOverrides(token: token),
        // 聚焦搜索框会取热门标签；给零延迟替身，避免 Pending timers。
        ...tagOverrides(),
        if (withDataSource)
          workDataSourceProvider.overrideWithValue(_FakeWorkSource()),
        appInitialLocationProvider.overrideWithValue(RoutePaths.contents),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// `AuthController.build` 用微任务恢复会话，等它跑完再读历史，
  /// 否则读到的永远是 `guest` 桶（理由见 `auth_controller_test.dart`）。
  Future<void> settleAuth(ProviderContainer container) async {
    var state = container.read(authControllerProvider);
    for (var i = 0; i < 50 && state.status == AuthStatus.checking; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      state = container.read(authControllerProvider);
    }
  }

  group('StringListCodec', () {
    test('整段坏掉是空列表，单条坏掉只跳过它自己', () {
      expect(StringListCodec.decode('这不是 JSON'), isEmpty);
      expect(StringListCodec.decode('{"a": 1}'), isEmpty);
      // 1 与 null 不是字符串，跳过；两端空白顺手去掉。
      expect(StringListCodec.decode('["进击", 1, null, "  EVA  "]'), [
        '进击',
        'EVA',
      ]);
    });
  });

  group('SearchHistoryController', () {
    test('去空白、去重不区分大小写、命中就置顶', () async {
      final container = createContainer();
      await settleAuth(container);
      final history = container.read(searchHistoryProvider.notifier);

      history.record('  NHK  ');
      history.record('进击的巨人');
      // 与第一条只差大小写：不是新的一条，而是把它挪到最前。
      history.record('nhk');

      expect(container.read(searchHistoryProvider), ['nhk', '进击的巨人']);
    });

    test('只记了空白等于没记', () async {
      final container = createContainer();
      await settleAuth(container);

      container.read(searchHistoryProvider.notifier).record('   ');
      expect(container.read(searchHistoryProvider), isEmpty);
    });

    test('超过上限时挤掉最早的一条', () async {
      final container = createContainer();
      await settleAuth(container);
      final history = container.read(searchHistoryProvider.notifier);

      for (var i = 1; i <= SearchHistoryController.maxEntries + 2; i++) {
        history.record('关键词 $i');
      }

      final values = container.read(searchHistoryProvider);
      expect(values, hasLength(SearchHistoryController.maxEntries));
      expect(values.first, '关键词 10');
      // 最早的「关键词 1」「关键词 2」被挤掉。
      expect(values, isNot(contains('关键词 1')));
      expect(values.last, '关键词 3');
    });

    test('remove 只删命中的一条，clear 清空', () async {
      final container = createContainer();
      await settleAuth(container);
      final history = container.read(searchHistoryProvider.notifier);

      history
        ..record('甲')
        ..record('乙')
        ..record('丙');

      history.remove('乙');
      expect(container.read(searchHistoryProvider), ['丙', '甲']);

      history.clear();
      expect(container.read(searchHistoryProvider), isEmpty);
    });

    test('换账号就换一份历史（未登录写 guest 桶）', () async {
      final prefs = InMemoryLocalPrefs();

      final guest = createContainer(prefs: prefs);
      await settleAuth(guest);
      guest.read(searchHistoryProvider.notifier).record('游客搜的');
      expect(guest.read(searchHistoryProvider), ['游客搜的']);

      final alice = createContainer(prefs: prefs, token: signedInToken);
      await settleAuth(alice);
      // 登录后读不到游客那条：历史会暴露「这台机器上有人在找什么」。
      expect(alice.read(searchHistoryProvider), isEmpty);

      alice.read(searchHistoryProvider.notifier).record('alice 搜的');
      expect(alice.read(searchHistoryProvider), ['alice 搜的']);
    });
  });

  group('搜索框上的历史 chips', () {
    Future<void> pumpContents(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const OtakuApp(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('边打字边搜不记历史，按搜索键才记', (tester) async {
      final container = createContainer(withDataSource: true);
      await pumpContents(tester, container);

      // 防抖链路（onChanged）跑了一遍搜索，但历史里不该留下打字过程。
      await tester.enterText(find.byType(TextField), '进击');
      await tester.pump(const Duration(milliseconds: 400));
      expect(container.read(contentsFilterProvider).query, '进击');
      expect(container.read(searchHistoryProvider), isEmpty);

      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(container.read(searchHistoryProvider), ['进击']);
    });

    testWidgets('只有在聚焦且输入框为空时才出现', (tester) async {
      final container = createContainer(withDataSource: true);
      container.read(searchHistoryProvider.notifier).record('进击');
      await pumpContents(tester, container);

      // 没聚焦：不占那一行高度。
      expect(find.text('最近搜索'), findsNothing);

      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(find.text('最近搜索'), findsOneWidget);
      expect(find.text('进击'), findsOneWidget);

      // 输入框里有词时收起来：两个焦点会让人分不清哪个才是当前查询。
      await tester.enterText(find.byType(TextField), '进击');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('最近搜索'), findsNothing);
    });

    testWidgets('点一条 chip 直接换上那个关键词', (tester) async {
      final container = createContainer(withDataSource: true);
      container.read(searchHistoryProvider.notifier).record('进击');
      await pumpContents(tester, container);

      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.tap(find.text('进击'));
      await tester.pump();

      expect(container.read(contentsFilterProvider).query, '进击');
      // 命中一次也算用过了，仍然只有一条（置顶而不是追加）。
      expect(container.read(searchHistoryProvider), ['进击']);
      expect(find.text('最近搜索'), findsNothing);
    });

    testWidgets('「清空」把整栏收起', (tester) async {
      final container = createContainer(withDataSource: true);
      container.read(searchHistoryProvider.notifier)
        ..record('甲')
        ..record('乙');
      await pumpContents(tester, container);

      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(find.text('最近搜索'), findsOneWidget);

      await tester.tap(find.text('清空'));
      await tester.pump();

      expect(container.read(searchHistoryProvider), isEmpty);
      expect(find.text('最近搜索'), findsNothing);
    });
  });
}
