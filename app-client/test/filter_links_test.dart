import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/app.dart';
import 'package:otaku_app/core/router/app_router.dart';
import 'package:otaku_app/core/router/route_paths.dart';
import 'package:otaku_app/data/datasources/work_data_source.dart';
import 'package:otaku_app/data/models/paged_result.dart';
import 'package:otaku_app/data/models/related_works.dart';
import 'package:otaku_app/data/models/work.dart';
import 'package:otaku_app/data/models/work_sort.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/data/repositories/work_repository.dart';
import 'package:otaku_app/features/contents/contents_controller.dart';
import 'package:otaku_app/features/detail/work_detail_page.dart';

import 'support/test_overrides.dart';

/// 永远返回 0 条：这一组用例只关心「筛选条件怎么变」，不关心列表内容。
class _EmptySource implements WorkDataSource {
  _EmptySource({this.detail});

  final Work? detail;

  @override
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    WorkSort sort = WorkSort.id,
    int page = 1,
    int pageSize = 20,
    List<String>? tags,
  
    int? year,}) async => const PagedResult<WorkSummary>(
    items: [],
    total: 0,
    page: 1,
    pageSize: 20,
    totalPages: 0,
  );

  @override
  Future<Work> fetchDetail(String workId) async => detail!;

  @override
  Future<RelatedWorks> fetchRelated(String workId, {int limit = 6}) async =>
      const RelatedWorks(basisTags: [], items: []);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child, {WorkDataSource? source}) => ProviderScope(
    overrides: [
      workDataSourceProvider.overrideWithValue(source ?? _EmptySource()),
      ...authOverrides(),
      // 聚焦搜索框会取热门标签；给零延迟替身，避免 Pending timers。
      ...tagOverrides(),
      appInitialLocationProvider.overrideWithValue(RoutePaths.contents),
    ],
    child: child,
  );

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  group('筛选条件的两个入口', () {
    test('showTag 只留标签：类型 / 关键词 / 排序一起清掉', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final filter = container.read(contentsFilterProvider.notifier);
      filter.selectType(WorkType.anime);
      filter.search('进击');
      filter.selectSort(WorkSort.rating);

      filter.showTag(' 科幻 ');

      final state = container.read(contentsFilterProvider);
      expect(state.tags, ['科幻']);
      expect(state.type, isNull);
      expect(state.query, isEmpty);
      // 从详情页跳过来是「看这个标签都有什么」，残留的排序会让首屏顺序
      // 与「按标签浏览」的直觉不一致，所以一起复位到默认的年份排序。
      expect(state.sort, WorkSort.year);
    });

    test('showTag 传空串不动现状', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final filter = container.read(contentsFilterProvider.notifier);
      filter.selectTag('科幻');

      filter.showTag('   ');

      expect(container.read(contentsFilterProvider).tags, ['科幻']);
    });

    test('clearFilters 清类型 / 关键词 / 标签，但保留排序', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final filter = container.read(contentsFilterProvider.notifier);
      filter.selectType(WorkType.anime);
      filter.search('进击');
      filter.selectTag('科幻');
      filter.selectSort(WorkSort.rating);

      filter.clearFilters();

      final state = container.read(contentsFilterProvider);
      expect(state.type, isNull);
      expect(state.query, isEmpty);
      expect(state.tags, isEmpty);
      // 排序不是筛选：清筛选不该把用户选的顺序也重置掉。
      expect(state.sort, WorkSort.rating);
    });
  });

  group('详情页点标签', () {
    const work = Work(
      workId: 'W-1',
      workType: WorkType.anime,
      title: '铁臂阿童木',
      source: 'otaku_site',
      sourceId: '662',
      tags: ['科幻', '机器人'],
    );

    testWidgets('点了标签只改条件，并清掉上一页残留的分类与关键词', (tester) async {
      await tester.pumpWidget(
        wrap(
          const MaterialApp(home: WorkDetailPage(workId: 'W-1')),
          source: _EmptySource(detail: work),
        ),
      );
      await settle(tester);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(WorkDetailPage)),
      );
      // 模拟「从筛过的列表点进来」：类型与关键词都还在。
      container.read(contentsFilterProvider.notifier).selectType(WorkType.anime);
      container.read(contentsFilterProvider.notifier).search('铁臂');

      await tester.tap(find.text('科幻'));
      await settle(tester);

      final state = container.read(contentsFilterProvider);
      expect(state.tags, ['科幻']);
      expect(state.type, isNull);
      expect(state.query, isEmpty);
    });
  });

  group('空结果', () {
    testWidgets('筛出 0 条时给「清除筛选」，点了关键词与条件一起清掉', (tester) async {
      await tester.pumpWidget(wrap(const OtakuApp()));
      await settle(tester);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(OtakuApp)),
      );

      await tester.enterText(find.byType(TextField).first, '不存在的标题');
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);

      expect(find.text('清除筛选'), findsOneWidget);

      await tester.tap(find.text('清除筛选'));
      await settle(tester);

      final state = container.read(contentsFilterProvider);
      expect(state.query, isEmpty);
      expect(state.type, isNull);
      expect(state.tags, isEmpty);
      // 输入框也要跟着空：只清条件不清输入框，用户会以为按钮没生效。
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller?.text ?? '', isEmpty);
      // 条件清空后不再是「筛太窄」，出口按钮也该收起来。
      expect(find.text('清除筛选'), findsNothing);
    });

    testWidgets('完全没数据时不给「清除筛选」——那不是点一下能解决的问题', (tester) async {
      await tester.pumpWidget(wrap(const OtakuApp()));
      await settle(tester);

      expect(find.text('这里还没有作品'), findsOneWidget);
      expect(find.text('清除筛选'), findsNothing);
    });
  });
}
