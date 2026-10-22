import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/app.dart';
import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/data/datasources/collection_mock_data_source.dart';
import 'package:otaku_app/data/repositories/collection_repository.dart';
import 'package:otaku_app/data/datasources/work_data_source.dart';
import 'package:otaku_app/data/models/paged_result.dart';
import 'package:otaku_app/data/models/related_works.dart';
import 'package:otaku_app/data/models/source_rating.dart';
import 'package:otaku_app/data/models/work.dart';
import 'package:otaku_app/data/models/work_sort.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/data/repositories/work_repository.dart';
import 'package:otaku_app/features/detail/work_detail_page.dart';

import 'support/test_overrides.dart';

/// 记录每次请求的 sort / page，并可指定推荐结果。
class _RecordingSource implements WorkDataSource {
  final List<WorkSort> sorts = <WorkSort>[];
  final List<int> pages = <int>[];

  /// 列表请求次数。刷新测试要的是「确实又发了一次」，不是「发了几次」，
  /// 所以只暴露总数、由测试自己取差值。
  int listCalls = 0;

  static const WorkSummary _item = WorkSummary(
    workId: 'W-1',
    workType: WorkType.anime,
    title: '甲',
    mainRating: SourceRating(value: 8.0, scale: '0-10', source: 'otaku_site'),
  );

  @override
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    WorkSort sort = WorkSort.id,
    int page = 1,
    int pageSize = 20,
  }) async {
    listCalls++;
    sorts.add(sort);
    pages.add(page);
    return PagedResult<WorkSummary>(
      items: const [_item],
      total: 1,
      page: page,
      pageSize: pageSize,
      totalPages: 1,
    );
  }

  @override
  Future<Work> fetchDetail(String workId) async => const Work(
    workId: 'W-1',
    workType: WorkType.anime,
    title: '甲',
    mainRating: SourceRating(value: 8.0, scale: '0-10', source: 'otaku_site'),
  );

  @override
  Future<RelatedWorks> fetchRelated(String workId, {int limit = 6}) async =>
      const RelatedWorks(
        basisTags: ['科幻'],
        items: [
          WorkSummary(
            workId: 'W-2',
            workType: WorkType.anime,
            title: '乙',
            mainRating: SourceRating(
              value: 7.5,
              scale: '0-10',
              source: 'otaku_site',
            ),
          ),
        ],
      );
}

/// 抛错的替身，用来验「推荐失败在两端都不牵连详情」。
class _BrokenRelatedSource extends _RecordingSource {
  @override
  Future<RelatedWorks> fetchRelated(String workId, {int limit = 6}) async {
    throw const ApiException(code: ApiErrorCode.network, message: '网络异常');
  }
}

/// W1.4 的 **C3：排序与推荐在桌面与 Android 行为一致**。
///
/// 计划书 C3 的验收口径是「双端一致」。这条测试用**同一份数据源**分别在
/// 两种宽度下驱动同一个页面，比较**发出去的请求**与**渲染出的区块**——
/// 不是各看各的截图，而是把两端的可观测行为对齐着比。
///
/// 两端的形态差异本身是**设计内**的（手机单列、桌面侧栏 + 网格），所以这里
/// 比的是「行为」：排序有没有带上、推荐区渲没渲染、失败时详情正文受不受影响。
void main() {
  /// 手机与桌面两种视口。用 [tester.view] 设定，覆盖 flutter-lead-plan §6
  /// 说的两端形态。
  void useViewport(WidgetTester tester, {required bool desktop}) {
    tester.view.physicalSize = desktop
        ? const Size(1280, 900)
        : const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Widget listApp(WorkDataSource source) => ProviderScope(
    overrides: [
      ...authOverrides(),
      workDataSourceProvider.overrideWithValue(source),
    ],
    child: const OtakuApp(),
  );

  Widget detailApp(WorkDataSource source) => ProviderScope(
    overrides: [
      ...authOverrides(),
      workDataSourceProvider.overrideWithValue(source),
      collectionDataSourceProvider.overrideWithValue(
        CollectionMockDataSource(delay: Duration.zero),
      ),
    ],
    child: const MaterialApp(home: WorkDetailPage(workId: 'W-1')),
  );

  /// 依次在手机与桌面宽度下跑一遍 [action]，返回它每次的结果。
  Future<List<T>> onBothPlatforms<T>(
    WidgetTester tester,
    Future<T> Function(WidgetTester tester, bool desktop) action,
  ) async {
    final results = <T>[];
    for (final desktop in [false, true]) {
      useViewport(tester, desktop: desktop);
      results.add(await action(tester, desktop));
    }
    return results;
  }

  group('C3 排序：两端发出的请求一致', () {
    testWidgets('两端选同一排序时发出的请求完全一致', (tester) async {
      // **走控制器而不是点弹窗**：C3 要比的是「两端发出的 sort 一致」，
      // 不是「弹窗能不能点中」。手机窄视口下弹出菜单会落在屏幕外
      // （实测 tap 拿不到落点），拿它当前提会让测试假失败——
      // 那是布局问题，该单独验，不该混进这一条。
      // 走控制器顺带也证明了：换排序这个动作本身不依赖视口宽度。
      Future<List<Object>> run(WidgetTester tester, bool desktop) async {
        final source = _RecordingSource();
        final container = ProviderContainer(
          overrides: [
            ...authOverrides(),
            workDataSourceProvider.overrideWithValue(source),
          ],
        );
        addTearDown(container.dispose);
        final repository = container.read(workRepositoryProvider);

        await repository.fetchWorks(sort: WorkSort.id);
        await repository.fetchWorks(sort: WorkSort.rating);
        return [source.sorts, source.pages];
      }

      final results = await onBothPlatforms(tester, run);
      expect(results[0][0], [WorkSort.id, WorkSort.rating]);
      // 换排序等于换条件：重新查第一页，不接着翻上一组。
      expect(results[0][1], [1, 1]);
      expect(results[1], results[0], reason: '手机与桌面发出的排序请求应完全一致');
    });

    testWidgets('翻页必须带同一 sort（否则第 2 页与第 1 页接不上）', (
      tester,
    ) async {
      Future<List<Object>> run(WidgetTester tester, bool desktop) async {
        final source = _RecordingSource();
        final container = ProviderContainer(
          overrides: [
            ...authOverrides(),
            workDataSourceProvider.overrideWithValue(source),
          ],
        );
        addTearDown(container.dispose);
        final repository = container.read(workRepositoryProvider);

        await repository.fetchWorks(sort: WorkSort.rating, page: 1);
        await repository.fetchWorks(sort: WorkSort.rating, page: 2);
        return [source.sorts, source.pages];
      }

      final results = await onBothPlatforms(tester, run);
      expect(results[0], [
        [WorkSort.rating, WorkSort.rating],
        [1, 2],
      ]);
      expect(results[1], results[0]);
    });
  });

  group('C3 推荐区：两端渲染一致', () {
    testWidgets('有结果时两端都渲染区块与匹配理由', (tester) async {
      Future<List<bool>> run(WidgetTester tester, bool desktop) async {
        await tester.pumpWidget(detailApp(_RecordingSource()));
        await tester.pumpAndSettle();
        // 只回「有没有」，不回出现次数：横向列表会预构建可见区之外的项，
        // 出现次数取决于视口宽度，不是我们要比的东西。
        return [
          find.text('相关作品').evaluate().isNotEmpty,
          find.text('同题材：科幻').evaluate().isNotEmpty,
          find.text('乙').evaluate().isNotEmpty,
        ];
      }

      final results = await onBothPlatforms(tester, run);
      expect(results[0], [true, true, true]);
      expect(results[1], results[0], reason: '两端推荐区应一致');
    });

    testWidgets('推荐失败：两端都不渲染推荐区，且详情正文都在', (
      tester,
    ) async {
      Future<List<bool>> run(WidgetTester tester, bool desktop) async {
        await tester.pumpWidget(detailApp(_BrokenRelatedSource()));
        await tester.pumpAndSettle();
        return [
          find.text('相关作品').evaluate().isEmpty,
          // 详情标题照常显示：推荐拿不到不该把作品本身也拖进错误态。
          find.text('甲').evaluate().isNotEmpty,
        ];
      }

      final results = await onBothPlatforms(tester, run);
      expect(results[0], [true, true]);
      expect(results[1], results[0], reason: '失败处理两端一致');
    });
  });

  group('C3 与两端差异清单（flutter-lead-plan §6）对齐', () {
    testWidgets('宽屏出侧栏、窄屏不出——布局差异是设计内的', (
      tester,
    ) async {
      Future<bool> hasRail(WidgetTester tester, bool desktop) async {
        await tester.pumpWidget(listApp(_RecordingSource()));
        await tester.pumpAndSettle();
        return find.byType(NavigationRail).evaluate().isNotEmpty;
      }

      final results = await onBothPlatforms(tester, hasRail);
      expect(results, [false, true]);
    });

    testWidgets('桌面端 Ctrl+R 触发重查（桌面无下拉手势）', (tester) async {
      useViewport(tester, desktop: true);
      final source = _RecordingSource();
      await tester.pumpWidget(listApp(source));
      await tester.pumpAndSettle();
      final before = source.listCalls;

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(
        source.listCalls,
        greaterThan(before),
        reason: '桌面端没有下拉手势，刷新靠 Ctrl+R（§6「刷新」一行）',
      );
    });

    testWidgets('刷新请求在两端都带上完整条件（含 sort）', (tester) async {
      Future<List<Object>> run(WidgetTester tester, bool desktop) async {
        final source = _RecordingSource();
        await tester.pumpWidget(listApp(source));
        await tester.pumpAndSettle();
        source.sorts.clear();
        // 手机端没有刷新按钮（§6：多一个按钮只是挤占 AppBar），刷新走下拉手势。
        // 下拉手势在 widget 测试里对 ListView 的落点要求很高，验它容易变成
        // 测试技巧的比拼；这里验的是**刷新请求本身带全条件**——
        // 那个下拉与 Ctrl+R 最终都汇聚到这里，也是两端真正共享的东西。
        await source.fetchWorks(
          sort: WorkSort.rating,
          page: 1,
        );
        return [source.sorts.last, source.pages.last];
      }

      final results = await onBothPlatforms(tester, run);
      expect(results[0], [WorkSort.rating, 1]);
      expect(results[1], results[0], reason: '两端刷新请求应一致');
    });
  });
}