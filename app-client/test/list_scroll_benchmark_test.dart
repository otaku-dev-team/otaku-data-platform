import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/app.dart';
import 'package:otaku_app/core/config/app_config.dart';
import 'package:otaku_app/data/datasources/work_data_source.dart';
import 'package:otaku_app/data/models/paged_result.dart';
import 'package:otaku_app/data/models/related_works.dart';
import 'package:otaku_app/data/models/work.dart';
import 'package:otaku_app/data/models/work_sort.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/source_rating.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/data/repositories/work_repository.dart';
import 'package:otaku_app/features/contents/contents_controller.dart';
import 'package:otaku_app/features/contents/work_card.dart';
import 'package:otaku_app/core/router/app_router.dart';
import 'package:otaku_app/core/router/route_paths.dart';

import 'support/test_overrides.dart';

/// 万级列表的渲染基线（阶段 3，见 `docs/stage3-performance-baseline.md`）。
///
/// 这里量的是**渲染**，不是网络：数据源一次性返回 N 条、单页，绕开分页，
/// 把「数据量」这个变量单独拎出来。分页的代价在另一个测试里单独统计。
///
/// ⚠️ `flutter test` 跑在 VM 的软件渲染下，**绝对耗时不代表真机**。
/// 这些数字只用来做两件事：① 判断复杂度是否 O(1)（1k 与 10k 应当同量级）；
/// ② 后续改动时做回归对比。真机帧率见同一份文档的 Windows profile 数据。
class _BulkDataSource implements WorkDataSource {
  _BulkDataSource(this.count);

  final int count;

  @override
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    WorkSort sort = WorkSort.id,
    int page = 1,
    int pageSize = 20,
    String? tag,
  }) async {
    final items = List<WorkSummary>.generate(
      count,
      (i) => WorkSummary(
        workId: 'W-perf-$i',
        workType: WorkType.values[i % WorkType.selectable.length],
        title: '性能样本作品标题 $i',
        // 一半有标签、一半没有：标签区会多一层 Wrap，属于真实场景。
        tags: i.isEven ? const ['日常', '搞笑'] : null,
        // 四分之一没有评分：徽标整块不渲染，少一层 Row。
        mainRating: i % 4 == 0
            ? null
            : const SourceRating(value: 7.8, scale: '0-10', source: 'perf'),
      ),
      growable: false,
    );
    return PagedResult<WorkSummary>(
      items: items,
      total: count,
      page: 1,
      pageSize: count,
      totalPages: 1,
    );
  }

  @override
  Future<Work> fetchDetail(String workId) async => throw UnimplementedError();

  @override
  Future<RelatedWorks> fetchRelated(String workId, {int limit = 6}) async =>
      const RelatedWorks(basisTags: <String>[], items: <WorkSummary>[]);
}

/// 真分页：每次只返回一页，用来统计「翻到底」到底要多少次请求。
class _PagedCountingDataSource implements WorkDataSource {
  _PagedCountingDataSource({required this.total});

  final int total;
  int calls = 0;

  @override
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    WorkSort sort = WorkSort.id,
    int page = 1,
    int pageSize = 20,
    String? tag,
  }) async {
    calls++;
    final start = (page - 1) * pageSize;
    final end = start + pageSize > total ? total : start + pageSize;
    return PagedResult<WorkSummary>(
      items: List<WorkSummary>.generate(
        end - start,
        (i) => WorkSummary(
          workId: 'W-page-$page-$i',
          workType: WorkType.anime,
          title: '分页样本 ${start + i}',
        ),
        growable: false,
      ),
      total: total,
      page: page,
      pageSize: pageSize,
      totalPages: (total / pageSize).ceil(),
    );
  }

  @override
  Future<RelatedWorks> fetchRelated(String workId, {int limit = 6}) async =>
      const RelatedWorks(basisTags: <String>[], items: <WorkSummary>[]);

  @override
  Future<Work> fetchDetail(String workId) async => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(WorkDataSource source) => ProviderScope(
    overrides: [
      appInitialLocationProvider.overrideWithValue(RoutePaths.contents),
      workDataSourceProvider.overrideWithValue(source),
      // 列表页的账号入口会创建 AuthController，测试里必须给内存令牌。
      ...authOverrides(),
    ],
    child: const OtakuApp(),
  );

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// 建表 + 首次布局的耗时。`pumpWidget` 只提交一帧，真正的布局在 `pump()` 里。
  Future<double> measureFirstFrame(WidgetTester tester, int count) async {
    final source = _BulkDataSource(count);
    final clock = Stopwatch()..start();
    await tester.pumpWidget(wrap(source));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    clock.stop();
    return clock.elapsedMicroseconds / 1000;
  }

  testWidgets('1k 与 10k 的首帧耗时同量级（列表是懒构建的）', (tester) async {
    // 桌面视口：1280 逻辑宽（150% 缩放下的常见值），高度按 900。
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 预热：第一次 pumpWidget 要初始化主题、字体、路由，冷启动耗时会串到
    // 第一个样本上（实测能把 1k 抬到 800ms 量级，纯属噪声）。
    await tester.pumpWidget(wrap(_BulkDataSource(0)));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    final first1k = await measureFirstFrame(tester, 1000);
    final cardsAfter1k = tester.widgetList(find.byType(WorkCard)).length;

    // 换一份 10k 的数据：先清空树，避免复用 State。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    final first10k = await measureFirstFrame(tester, 10000);
    final cardsAfter10k = tester.widgetList(find.byType(WorkCard)).length;

    // ignore: avoid_print
    print(
      '[perf] 首帧 1k=${first1k.toStringAsFixed(1)}ms 10k=${first10k.toStringAsFixed(1)}ms '
      '已构建卡片 1k=$cardsAfter1k 10k=$cardsAfter10k',
    );

    // 数据量翻 10 倍，构建的卡片数必须基本不变——这才是"懒加载"的证据。
    // 允许 ±30% 的浮动（视口取整、缓存区边界）。
    expect(cardsAfter10k, lessThan(cardsAfter1k * 1.3 + 8));
    // 10k 的首帧不该出现数量级差异（超过 4 倍说明有 O(n) 的环节）。
    expect(first10k, lessThan(first1k * 4 + 50));
  });

  testWidgets('连续滚动 600 步：帧耗时与已构建卡片数', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(wrap(_BulkDataSource(10000)));
    await settle(tester);

    final scrollable = find.byType(CustomScrollView);
    final samples = <double>[];
    for (var i = 0; i < 600; i++) {
      final clock = Stopwatch()..start();
      await tester.drag(scrollable, const Offset(0, -240));
      await tester.pump();
      clock.stop();
      samples.add(clock.elapsedMicroseconds / 1000);
    }

    samples.sort();
    final p50 = samples[samples.length ~/ 2];
    final p95 = samples[(samples.length * 0.95).floor()];
    final max = samples.last;
    final cards = tester.widgetList(find.byType(WorkCard)).length;

    // ignore: avoid_print
    print(
      '[perf] 滚动 600 步 共 10000 条：p50=${p50.toStringAsFixed(2)}ms '
      'p95=${p95.toStringAsFixed(2)}ms max=${max.toStringAsFixed(2)}ms '
      '当前在树卡片=$cards',
    );

    // 滚到深处后，树里的卡片数仍然只跟视口挂钩，不随滚过的数量增长。
    expect(cards, lessThan(200));
  });

  test('滚完 10000 条要发多少次请求（分页策略的真实代价）', () async {
    // 这不是渲染问题，是分页策略问题：请求次数 = 总量 / 单页条数。
    // pageSize=20 要 500 次，取契约上限 50 只需 200 次——这个数字比帧率更值得讨论。
    final source = _PagedCountingDataSource(total: 10000);
    final container = ProviderContainer(
      overrides: [workDataSourceProvider.overrideWithValue(source)],
    );
    addTearDown(container.dispose);

    // 首屏一页，然后一直翻到底。
    await container.read(contentsControllerProvider.future);
    var guard = 0;
    while (container.read(contentsControllerProvider).requireValue.hasMore) {
      await container.read(contentsControllerProvider.notifier).loadMore();
      if (++guard > 2000) fail('翻页没有终止，hasMore 判定可疑');
    }

    final data = container.read(contentsControllerProvider).requireValue;
    expect(data.items.length, 10000);
    expect(source.calls, (10000 / AppConfig.pageSize).ceil());
    // ignore: avoid_print
    print('[perf] 10000 条共发起 ${source.calls} 次请求');
  });
}
