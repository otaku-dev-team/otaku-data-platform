import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/app.dart';
import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/core/router/app_router.dart';
import 'package:otaku_app/core/router/route_paths.dart';
import 'package:otaku_app/core/storage/memory_work_cache.dart';
import 'package:otaku_app/core/storage/work_cache_provider.dart';
import 'package:otaku_app/data/datasources/schedule_data_source.dart';
import 'package:otaku_app/data/datasources/work_data_source.dart';
import 'package:otaku_app/data/models/paged_result.dart';
import 'package:otaku_app/data/models/related_works.dart';
import 'package:otaku_app/data/models/schedule.dart';
import 'package:otaku_app/data/models/work.dart';
import 'package:otaku_app/data/models/work_sort.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/repositories/schedule_repository.dart';
import 'package:otaku_app/data/repositories/work_repository.dart';
import 'package:otaku_app/shared/widgets/skeleton_list.dart';
import 'package:otaku_app/features/contents/catalog_counts.dart';
import 'package:otaku_app/features/contents/contents_controller.dart';
import 'package:otaku_app/features/contents/contents_page.dart';
import 'package:otaku_app/features/schedule/schedule_controller.dart';

import 'support/test_overrides.dart';

/// 真实数据驱动的渲染走查。
///
/// 数据不是手写的假对象，而是**从运行中的真后端拉回来存下的响应原文**
/// （`test/fixtures/real_*.json`，拉取方式见 `docs/w1-real-data-probe.md` §1）。
/// 这样测的是「真实数据形状 → 模型解析 → 界面渲染」整条链，而不是
/// 「我认为数据长什么样」。
///
/// 覆盖人工走查清单里**不需要人眼**的部分：溢出、占位、空态文案、错误态。
/// 主观体验（动效、观感）仍然要人，见该文档 §5。
class _FixtureWorkSource implements WorkDataSource {
  _FixtureWorkSource(this.page, {this.detail, this.error});

  final PagedResult<WorkSummary> page;
  final Work? detail;
  final ApiException? error;

  @override
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    WorkSort sort = WorkSort.id,
    int page = 1,
    int pageSize = 20,
    String? tag,
  }) async {
    final failure = error;
    if (failure != null) throw failure;
    return this.page;
  }

  @override
  Future<Work> fetchDetail(String workId) async => detail!;

  @override
  Future<RelatedWorks> fetchRelated(String workId, {int limit = 6}) async =>
      const RelatedWorks(basisTags: [], items: []);
}

class _FixtureScheduleSource implements ScheduleDataSource {
  _FixtureScheduleSource(this.page);

  final SchedulePageData page;

  @override
  Future<SchedulePageData> fetchSchedule({String? season}) async => page;
}

/// 每次被调用就计一次数，然后失败。用来看「失败后有没有在偷偷重试」。
class _CountingFailingSource implements WorkDataSource {
  _CountingFailingSource(this.onCall);

  final void Function() onCall;

  @override
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    WorkSort sort = WorkSort.id,
    int page = 1,
    int pageSize = 20,
    String? tag,
  }) async {
    onCall();
    throw const ApiException(code: ApiErrorCode.network, message: '网络不可达');
  }

  @override
  Future<Work> fetchDetail(String workId) async =>
      throw const ApiException(code: ApiErrorCode.network, message: '网络不可达');

  @override
  Future<RelatedWorks> fetchRelated(String workId, {int limit = 6}) async =>
      throw const ApiException(code: ApiErrorCode.network, message: '网络不可达');
}

/// 同上，档期专用。
class _CountingScheduleSource implements ScheduleDataSource {
  _CountingScheduleSource(this.onCall);

  final void Function() onCall;

  @override
  Future<SchedulePageData> fetchSchedule({String? season}) async {
    onCall();
    throw const ApiException(code: ApiErrorCode.network, message: '网络不可达');
  }
}

PagedResult<WorkSummary> _loadWorks(String name) {
  final json = jsonDecode(
    File('test/fixtures/$name.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final items = (json['items'] as List)
      .map((e) => WorkSummary.fromJson(e as Map<String, dynamic>))
      .toList(growable: false);
  return PagedResult<WorkSummary>(
    items: items,
    total: json['total'] as int,
    page: json['page'] as int,
    pageSize: json['page_size'] as int,
    totalPages: json['total_pages'] as int,
  );
}

Work _loadDetail(String name) =>
    Work.fromJson(jsonDecode(File('test/fixtures/$name.json').readAsStringSync()));

SchedulePageData _loadSchedule(String name) =>
    SchedulePageData.fromJson(
      jsonDecode(File('test/fixtures/$name.json').readAsStringSync()),
    );

/// 长标题那条真实数据的标题长度（146 字符，库里最长）。
const int _longTitleLength = 146;

void main() {
  /// 列表页：落点钉在 `/works`，省掉首页那几次请求。
  ProviderContainer worksContainer(_FixtureWorkSource source) {
    final container = ProviderContainer(
      overrides: [
        ...authOverrides(),
        appInitialLocationProvider.overrideWithValue(RoutePaths.contents),
        workDataSourceProvider.overrideWithValue(source),
        workCacheProvider.overrideWithValue(InMemoryWorkCache()),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> pumpApp(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const OtakuApp()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  group('真实数据渲染（fixture 来自运行中的真后端）', () {
    testWidgets('146 字符的长标题：截断为两行，不溢出', (tester) async {
      final container = worksContainer(_FixtureWorkSource(_loadWorks('real_works_long_title')));
      await pumpApp(tester, container);

      expect(tester.takeException(), isNull,
          reason: 'render overflow 会以异常抛出——长标题把卡片撑破就是这条');
      final title = tester.widget<Text>(
        find.textContaining('If Letters Had Pants'),
      );
      expect(title.maxLines, 2, reason: '标题必须自己截断，不能把网格撑变形');
      expect(title.data!.length, _longTitleLength);
    });

    testWidgets('按评分排序 + 结果全无评分：说明条与逐条标注都出现', (tester) async {
      // 真实最后一页：17 条，全部无评分、无封面。
      final container = worksContainer(_FixtureWorkSource(_loadWorks('real_works_rating_tail')));
      container.read(contentsFilterProvider.notifier).selectSort(WorkSort.rating);
      await pumpApp(tester, container);

      expect(find.text('没有评分的作品排在最后'), findsOneWidget,
          reason: 'D2：无评分是常态（63.8%），必须解释，不能让人以为加载失败');
      expect(find.text('暂无评分'), findsWidgets,
          reason: '逐条标注——只有说明条，用户还是要逐条猜');
    });

    testWidgets('全都有评分时：不出现 D2 的说明条与标注', (tester) async {
      final container = worksContainer(_FixtureWorkSource(_loadWorks('real_works_default')));
      container.read(contentsFilterProvider.notifier).selectSort(WorkSort.rating);
      await pumpApp(tester, container);

      expect(find.text('没有评分的作品排在最后'), findsNothing);
      expect(find.text('暂无评分'), findsNothing);
    });

    testWidgets('无封面的条目：显示作品首字占位，不留白', (tester) async {
      // 真实评分排序第 1 页：50 条全部无封面。
      final container = worksContainer(_FixtureWorkSource(_loadWorks('real_works_by_rating')));
      await pumpApp(tester, container);

      expect(tester.takeException(), isNull);
      // 首条标题的首字作为占位字符（CoverImage 的 placeholderLabel）。
      expect(find.text('グ'), findsWidgets,
          reason: '无封面不是空白，也不是破图——契约 6.3 的三态之一');
    });

    testWidgets('未知标签：空态说清「没有这个标签的作品」，并给清除出口', (tester) async {
      final container = worksContainer(_FixtureWorkSource(_loadWorks('real_works_unknown_tag')));
      container.read(contentsFilterProvider.notifier).selectTag('zzz-not-exist-tag');
      await pumpApp(tester, container);

      expect(find.text('没有这个标签的作品'), findsOneWidget);
      expect(find.textContaining('精确匹配'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '清除筛选'), findsOneWidget,
          reason: '筛太窄时必须给出口，否则用户只能自己想起来去改');
    });

    testWidgets('网络不可达：显示错误态，不无限转圈', (tester) async {
      final container = ProviderContainer(
        overrides: [
          ...authOverrides(),
          workDataSourceProvider.overrideWithValue(
            _FixtureWorkSource(
              _loadWorks('real_works_default'),
              error: const ApiException(code: ApiErrorCode.network, message: '网络不可达'),
            ),
          ),
          workCacheProvider.overrideWithValue(InMemoryWorkCache()),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ContentsPage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('网络好像不太行'), findsOneWidget);
      expect(find.byType(SkeletonList), findsNothing,
          reason: '失败后不能还挂着骨架屏——那看起来像还在加载');
      expect(find.byType(SkeletonGrid), findsNothing,
          reason: '失败后不能还挂着骨架屏——那看起来像还在加载');
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: '失败不能伪装成一直在加载');
      // 把所有零延迟的后续任务跑完（认证恢复、provider 落定）。
      // 这一步同时是「没有后台重试在排队」的证据：Riverpod 3 默认重试会挂一个
      // 200ms→6400ms 的退避 Timer，测试会以 timersPending 收场。
      await tester.pumpAndSettle(const Duration(seconds: 2));
    });
  });

  group('档期页（真实档期数据）', () {
    testWidgets('按周几分组渲染，条目可点区域存在', (tester) async {
      final container = ProviderContainer(
        overrides: [
          ...authOverrides(),
          appInitialLocationProvider.overrideWithValue(RoutePaths.schedule),
          scheduleDataSourceProvider.overrideWithValue(
            _FixtureScheduleSource(_loadSchedule('real_schedule')),
          ),
        ],
      );
      addTearDown(container.dispose);
      // 让季度保持默认（最新），别让筛选状态影响首屏。
      container.read(scheduleSeasonProvider.notifier).select(null);
      await pumpApp(tester, container);

      expect(find.text('周一'), findsWidgets);
      expect(find.text('周二'), findsWidgets);
      // 真实第一条档期的标题（来自 202610 季度）。
      expect(find.text('PSYREN 决战游戏'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('详情页（真实长标题条目）', () {
    testWidgets('146 字符标题 + 无评分 + 无封面：不溢出、不假报', (tester) async {
      final detail = _loadDetail('real_work_detail_long');
      expect(detail.title.length, _longTitleLength);
      expect(detail.mainRating, isNull);
      expect(detail.coverUrl, isNull);

      final container = ProviderContainer(
        overrides: [
          ...authOverrides(),
          appInitialLocationProvider.overrideWithValue(RoutePaths.contents),
          workDataSourceProvider.overrideWithValue(
            _FixtureWorkSource(_loadWorks('real_works_long_title'), detail: detail),
          ),
          workCacheProvider.overrideWithValue(InMemoryWorkCache()),
        ],
      );
      addTearDown(container.dispose);
      await pumpApp(tester, container);

      await tester.tap(find.textContaining('If Letters Had Pants'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));

      expect(tester.takeException(), isNull, reason: '详情页同样不能溢出');
      expect(find.textContaining('If Letters Had Pants'), findsWidgets);
      expect(find.text('0.0'), findsNothing,
          reason: '契约 6.3：没有评分不能显示 0.0');
    });
  });

  group('后台重试守卫', () {
    // 这组不测界面，测的是「失败后会不会还在偷偷重试」。
    //
    // Riverpod 3 的默认重试是 200ms→6400ms 退避、最多 10 次。挂在页面上的
    // provider 一旦漏了 `retry: (n, e) => null`，表现是：
    //   - 失败被伪装成"一直在加载"，错误提示要等十几秒才出现；
    //   - 每次重试都真打后端（catalogCounts 一次并发 5 个请求）；
    //   - 组件卸载后 Timer 还在，测试以 timersPending 收场。
    // 前两条用户看得见，第三条只有测试看得见——所以三条都要钉住。

    test('角标失败后不重试（不重打后端、不留退避 Timer）', () async {
      var calls = 0;
      final container = ProviderContainer(
        overrides: [
          workDataSourceProvider.overrideWithValue(
            _CountingFailingSource(() => calls++),
          ),
          workCacheProvider.overrideWithValue(InMemoryWorkCache()),
        ],
      );
      addTearDown(container.dispose);

      await expectLater(
        container.read(catalogCountsProvider.future),
        throwsA(isA<ApiException>()),
      );
      // 一次拉取本来就并发 5 个请求（总数 + 四个类型），这是预期。
      final afterFirst = calls;
      expect(afterFirst, 5, reason: '一次拉取是 5 个并发请求，不是 5 次重试');

      // 等过最长的退避窗口（默认重试第一次就要 200ms），次数不该再涨。
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(calls, afterFirst, reason: '失败后不该再打后端');
      expect(
        container.read(catalogCountsProvider).hasError,
        isTrue,
        reason: '失败要立刻可见，而不是被重试掩盖成加载中',
      );
    });

    test('档期失败后不重试（错误提示立刻出现，不卡成转圈）', () async {
      var calls = 0;
      final container = ProviderContainer(
        overrides: [
          scheduleDataSourceProvider.overrideWithValue(
            _CountingScheduleSource(() => calls++),
          ),
        ],
      );
      addTearDown(container.dispose);

      await expectLater(
        container.read(scheduleProvider.future),
        throwsA(isA<ApiException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(calls, 1, reason: '失败后不该再打后端');
      final state = container.read(scheduleProvider);
      expect(state.hasError, isTrue, reason: '档期页要立刻能显示错误态');
      expect(state.isLoading, isFalse,
          reason: 'Riverpod 3 默认重试期间 isLoading 与 hasError 同真——那是「失败看起来像加载中」的根源');
    });
  });
}
