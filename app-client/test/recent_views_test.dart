import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/app.dart';
import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/core/router/app_router.dart';
import 'package:otaku_app/core/router/route_paths.dart';
import 'package:otaku_app/core/storage/memory_recent_views_store.dart';
import 'package:otaku_app/core/storage/recent_views_provider.dart';
import 'package:otaku_app/core/storage/recent_views_store.dart';
import 'package:otaku_app/data/datasources/article_data_source.dart';
import 'package:otaku_app/data/datasources/schedule_data_source.dart';
import 'package:otaku_app/data/datasources/work_data_source.dart';
import 'package:otaku_app/data/models/article.dart';
import 'package:otaku_app/data/models/paged_result.dart';
import 'package:otaku_app/data/models/recent_view.dart';
import 'package:otaku_app/data/models/related_works.dart';
import 'package:otaku_app/data/models/schedule.dart';
import 'package:otaku_app/data/models/source_rating.dart';
import 'package:otaku_app/data/models/work.dart';
import 'package:otaku_app/data/models/work_sort.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/data/repositories/article_repository.dart';
import 'package:otaku_app/data/repositories/schedule_repository.dart';
import 'package:otaku_app/data/repositories/work_repository.dart';
import 'package:otaku_app/features/detail/work_detail_page.dart';
import 'package:otaku_app/features/recent/recent_views_controller.dart';
import 'package:otaku_app/features/recent/recent_history_page.dart';
import 'package:otaku_app/shared/widgets/compact_work_card.dart';

import 'support/test_overrides.dart';

Work _work(String workId, {String? title, ApiException? error}) {
  if (error != null) throw error;
  return Work(
    workId: workId,
    workType: WorkType.anime,
    title: title ?? '作品 $workId',
    releaseYear: 2020,
    mainRating: const SourceRating(
      value: 8.6,
      scale: '0-10',
      source: 'bangumi',
    ),
  );
}

class _FakeWorkSource implements WorkDataSource {
  _FakeWorkSource({this.detailError});

  /// 非 null 时详情请求失败。用来验证「打不开的页面不进历史」。
  final ApiException? detailError;

  static const summary = WorkSummary(
    workId: 'W-1',
    workType: WorkType.anime,
    title: '列表里的甲',
    releaseYear: 2020,
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
      _work(workId, title: '详情里的甲', error: detailError);

  @override
  Future<RelatedWorks> fetchRelated(String workId, {int limit = 6}) async =>
      const RelatedWorks(basisTags: <String>[], items: <WorkSummary>[]);
}

class _EmptyArticleSource implements ArticleDataSource {
  @override
  Future<PagedResult<ArticleSummary>> fetchArticles({
    String? category,
    int page = 1,
    int pageSize = 20,
  }) async {
    return PagedResult<ArticleSummary>(
      items: const [],
      total: 0,
      page: 1,
      pageSize: pageSize,
      totalPages: 1,
    );
  }

  @override
  Future<ArticleDetail> fetchDetail(String articleId) async =>
      throw UnimplementedError();

  @override
  Future<List<ArticleCategory>> fetchCategories() async => const [];
}

class _EmptyScheduleSource implements ScheduleDataSource {
  @override
  Future<SchedulePageData> fetchSchedule({String? season}) async =>
      const SchedulePageData(season: '202610', seasons: ['202610'], groups: []);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RecentViewsCodec', () {
    test('往返一趟后字段不丢，时间按 UTC 存、按本地读', () {
      final view = RecentView.of(
        _work('W-1'),
        viewedAt: DateTime(2026, 10, 23, 20, 15),
      );
      final decoded = RecentViewsCodec.decode(RecentViewsCodec.encode([view]));

      expect(decoded, hasLength(1));
      expect(decoded.single.workId, 'W-1');
      expect(decoded.single.work.title, '作品 W-1');
      expect(decoded.single.work.releaseYear, 2020);
      expect(decoded.single.work.mainRating?.value, 8.6);
      expect(decoded.single.viewedAt, DateTime(2026, 10, 23, 20, 15));
    });

    test('坏掉的那一条只跳过它自己，其余照常解析', () {
      final good = RecentView.of(
        _work('W-1'),
        viewedAt: DateTime(2026, 10, 23),
      );
      final raw = jsonEncode([
        good.toJson(),
        // 缺 title：内层 WorkSummary.fromJson 会抛 FormatException。
        {
          'work': {'work_id': 'W-2'},
          'viewed_at': '2026-10-23T00:00:00Z',
        },
        // 时间不合法。
        {
          'work': {'work_id': 'W-3', 'work_type': 'anime', 'title': '丙'},
          'viewed_at': '昨天',
        },
        'not-a-map',
      ]);

      final decoded = RecentViewsCodec.decode(raw);

      // 整段作废会让用户以为历史被清空了；正确做法是留下能认出来的那些。
      expect(decoded.map((item) => item.workId), ['W-1']);
    });

    test('整段不是 JSON 时返回空列表，不抛', () {
      expect(RecentViewsCodec.decode('{不是 json'), isEmpty);
      expect(RecentViewsCodec.decode('{}'), isEmpty);
    });
  });

  group('RecentViewsController', () {
    ProviderContainer createContainer() {
      final container = ProviderContainer(
        overrides: [
          ...authOverrides(),
          recentViewsStoreProvider.overrideWithValue(
            InMemoryRecentViewsStore(),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('删单条只影响那一条，其余顺序不变', () {
      final container = createContainer();
      final controller = container.read(recentViewsProvider.notifier);

      controller.record(_work('A'), at: DateTime(2026, 10, 1));
      controller.record(_work('B'), at: DateTime(2026, 10, 2));
      controller.record(_work('C'), at: DateTime(2026, 10, 3));

      controller.remove('B');

      expect(
        container.read(recentViewsProvider).map((e) => e.workId),
        ['C', 'A'],
      );
    });

    test('删不存在的 id 不改状态（连点两次不该出错）', () {
      final container = createContainer();
      final controller = container.read(recentViewsProvider.notifier);
      controller.record(_work('A'), at: DateTime(2026, 10, 1));

      controller.remove('不存在');
      controller.remove('A');
      controller.remove('A');

      expect(container.read(recentViewsProvider), isEmpty);
    });

    test('撤销放回原来的位置，不是置顶', () {
      final container = createContainer();
      final controller = container.read(recentViewsProvider.notifier);
      controller.record(_work('A'), at: DateTime(2026, 10, 1));
      controller.record(_work('B'), at: DateTime(2026, 10, 2));
      controller.record(_work('C'), at: DateTime(2026, 10, 3));

      // 顺序是 [C, B, A]；删掉中间的 B，再撤销。
      final removed = container
          .read(recentViewsProvider)
          .firstWhere((e) => e.workId == 'B');
      controller.remove('B');
      controller.restore(removed, 1);

      expect(
        container.read(recentViewsProvider).map((e) => e.workId),
        ['C', 'B', 'A'],
      );
    });

    test('再次打开同一作品是「置顶 + 换时间」，不是新增一条', () {
      final container = createContainer();
      final controller = container.read(recentViewsProvider.notifier);

      controller.record(_work('A'), at: DateTime(2026, 10, 1));
      controller.record(_work('B'), at: DateTime(2026, 10, 2));
      controller.record(_work('A'), at: DateTime(2026, 10, 3));

      final items = container.read(recentViewsProvider);
      expect(items.map((item) => item.workId), ['A', 'B']);
      expect(items.first.viewedAt, DateTime(2026, 10, 3));
    });

    test('超过上限时丢最旧的', () {
      final container = createContainer();
      final controller = container.read(recentViewsProvider.notifier);
      const total = RecentViewsController.maxEntries + 3;

      for (var i = 0; i < total; i++) {
        controller.record(_work('W-$i'), at: DateTime(2026, 10, 1));
      }

      final items = container.read(recentViewsProvider);
      expect(items, hasLength(RecentViewsController.maxEntries));
      expect(items.first.workId, 'W-${total - 1}');
      expect(items.last.workId, 'W-3');
    });

    test('写进去的历史能读回来：同一次运行内换容器也在', () async {
      final store = InMemoryRecentViewsStore();
      final first = ProviderContainer(
        overrides: [
          ...authOverrides(),
          recentViewsStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(first.dispose);
      first
          .read(recentViewsProvider.notifier)
          .record(_work('A'), at: DateTime(2026, 10, 1));

      // 模拟「重启 App」：新容器、同一个存储。
      final second = ProviderContainer(
        overrides: [
          ...authOverrides(),
          recentViewsStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(second.dispose);

      expect(second.read(recentViewsProvider).single.workId, 'A');
    });

    test('不同账号的历史互不可见', () async {
      final store = InMemoryRecentViewsStore();
      await store.write('guest', [
        RecentView.of(_work('游客看过的'), viewedAt: DateTime(2026, 10, 1)),
      ]);
      await store.write('u-1', [
        RecentView.of(_work('甲看过的'), viewedAt: DateTime(2026, 10, 1)),
      ]);

      expect(store.read('guest').single.workId, '游客看过的');
      expect(store.read('u-1').single.workId, '甲看过的');
      expect(store.read('u-2'), isEmpty);
    });
  });

  group('首页的「最近浏览」', () {
    Future<ProviderContainer> pumpApp(
      WidgetTester tester, {
      _FakeWorkSource? work,
      InMemoryRecentViewsStore? store,
    }) async {
      // 首页是纵向长内容，默认 800×600 装不下；放大窗口而不是模拟滚动。
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...authOverrides(),
            workDataSourceProvider.overrideWithValue(work ?? _FakeWorkSource()),
            articleDataSourceProvider.overrideWithValue(_EmptyArticleSource()),
            scheduleDataSourceProvider.overrideWithValue(
              _EmptyScheduleSource(),
            ),
            recentViewsStoreProvider.overrideWithValue(
              store ?? InMemoryRecentViewsStore(),
            ),
            appInitialLocationProvider.overrideWithValue(RoutePaths.contents),
          ],
          child: const OtakuApp(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      return ProviderScope.containerOf(tester.element(find.byType(OtakuApp)));
    }

    Future<void> goHome(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      container.read(appRouterProvider).go(RoutePaths.home);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('没看过任何作品时，首页不出现这一块', (tester) async {
      final container = await pumpApp(tester);
      await goHome(tester, container);

      expect(find.text('分类浏览'), findsOneWidget);
      // 首页也套着桌面外壳：侧栏在，落地页才出得去。
      expect(find.byType(NavigationRail), findsOneWidget);
      // 新用户的第一屏不该顶着一行空的「最近浏览」。
      expect(find.text('最近浏览'), findsNothing);
    });

    testWidgets('首页只露最近几条；从「全部」进列表页清空后这一块整体消失', (tester) async {
      final container = await pumpApp(tester);

      // 列表页 → 详情
      await tester.tap(find.text('列表里的甲'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(WorkDetailPage), findsOneWidget);

      // 详情记的是详情接口返回的那份快照，不是列表里那份。
      expect(container.read(recentViewsProvider).single.work.title, '详情里的甲');

      await goHome(tester, container);

      expect(find.text('最近浏览'), findsOneWidget);
      // 高分作品本来就有一张卡，加上最近浏览这一张。
      expect(find.byType(CompactWorkCard), findsNWidgets(2));
      expect(find.text('详情里的甲'), findsOneWidget);

      // 首页不再直接放「清空」——改成进「全部」列表页，清空在那一页的右上角。
      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();

      expect(find.byType(RecentHistoryPage), findsOneWidget);
      // 刚看过的落在「今天」这一段里。
      expect(find.text('今天'), findsOneWidget);
      expect(find.text('详情里的甲'), findsOneWidget);

      await tester.tap(find.byTooltip('清空'));
      await tester.pumpAndSettle();
      expect(find.text('清空最近浏览？'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '清空'));
      await tester.pumpAndSettle();

      expect(container.read(recentViewsProvider), isEmpty);
      expect(find.text('还没有浏览记录'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('最近浏览'), findsNothing);
      expect(find.byType(CompactWorkCard), findsOneWidget);
    });

    testWidgets('详情打不开时不留记录', (tester) async {
      final container = await pumpApp(
        tester,
        work: _FakeWorkSource(
          detailError: const ApiException(
            code: ApiErrorCode.network,
            message: '网络不可用',
          ),
        ),
      );

      await tester.tap(find.text('列表里的甲'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 界面上是错误态，历史里什么都不该多出来。
      expect(container.read(recentViewsProvider), isEmpty);
    });
  });
}
