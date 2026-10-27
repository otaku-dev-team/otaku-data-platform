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
import 'package:otaku_app/shared/widgets/cover_image.dart';
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
    List<String>? tags,
  
    int? year,}) async {
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
    List<String>? tags,
  
    int? year,}) async {
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

/// 按季度返回不同数据的档期源，用来验证「切季度真的换了内容」。
class _SeasonalScheduleSource implements ScheduleDataSource {
  _SeasonalScheduleSource(this.bySeason, {this.defaultPage});

  /// 键是季度码（如 `202610`）；值为该季度的响应。
  final Map<String, SchedulePageData> bySeason;

  /// 未指定季度时返回哪个（一般是最新季）。
  final SchedulePageData? defaultPage;

  /// 记录每次被请求的季度，用来断言「切换确实重新拉了」。
  final List<String?> requested = <String?>[];

  @override
  Future<SchedulePageData> fetchSchedule({String? season}) async {
    requested.add(season);
    final page = season == null ? defaultPage : bySeason[season];
    if (page == null) {
      throw const ApiException(
        code: ApiErrorCode.workNotFound,
        message: '该季度没有档期',
      );
    }
    return page;
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

    testWidgets('切季度：重新拉该季度的数据，标题与季度标签都换掉', (tester) async {
      final source = _SeasonalScheduleSource(
        {
          '202610': _loadSchedule('real_schedule'),
          '202607': _loadSchedule('real_schedule_prev_season'),
        },
        defaultPage: _loadSchedule('real_schedule'),
      );
      final container = ProviderContainer(
        overrides: [
          ...authOverrides(),
          appInitialLocationProvider.overrideWithValue(RoutePaths.schedule),
          scheduleDataSourceProvider.overrideWithValue(source),
        ],
      );
      addTearDown(container.dispose);
      container.read(scheduleSeasonProvider.notifier).select(null);
      await pumpApp(tester, container);

      // 默认是最新季 202610。
      expect(find.text('2026 年 10 月'), findsWidgets);
      expect(find.text('PSYREN 决战游戏'), findsWidgets);

      // 打开季度下拉，选 202607。
      await tester.tap(find.byTooltip('切换季度'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('2026 年 7 月'), findsWidgets,
          reason: '下拉里要列出可选季度');
      await tester.tap(find.text('2026 年 7 月').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 内容换成了那一季的：旧标题消失，新标题出现。
      expect(find.text('与奔跑在透明之夜的你 谈一场看不见的恋爱'), findsWidgets);
      expect(find.text('PSYREN 决战游戏'), findsNothing,
          reason: '切了季度还留着上一季的条目，说明筛选没生效');
      // 季度标签也跟着换。
      expect(find.text('2026 年 7 月'), findsWidgets);
      // 并且确实重新请求了那个季度，而不是只换了本地显示。
      expect(source.requested, contains('202607'));
    });

    testWidgets('未收录的条目：只展示不跳转，并说明原因', (tester) async {
      final page = _loadSchedule('real_schedule');
      // 真实数据里确实有 5 条没有 work_id（本站未收录）。
      final orphan = page.groups
          .expand((g) => g.items)
          .where((e) => e.workId == null || e.workId!.isEmpty)
          .toList();
      expect(orphan, isNotEmpty, reason: '真实档期里应当有未收录的条目');

      final container = ProviderContainer(
        overrides: [
          ...authOverrides(),
          appInitialLocationProvider.overrideWithValue(RoutePaths.schedule),
          scheduleDataSourceProvider.overrideWithValue(
            _FixtureScheduleSource(page),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(scheduleSeasonProvider.notifier).select(null);
      await pumpApp(tester, container);

      // 切到那条未收录条目所在的星期，让它在首屏。
      // （ListView 惰性构建，靠滚动找会 flaky；而星期筛选本身就是被测行为之一。）
      final weekday = orphan.first.weekday;
      expect(weekday, isNotNull);
      container.read(scheduleWeekdayProvider.notifier).select(
        ScheduleWeekday.values.firstWhere(
          (w) => w.backendValue == weekday && w != ScheduleWeekday.all,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // 展示出来了，并写明「仅展示档期信息」。
      // 它在周六组的第 16 位，超出测试视口，所以要滚。
      // ⚠️ `scrollUntilVisible` 的 scrollable 参数要 `Scrollable` widget 本身，
      // 不是 `ListView`（传 ListView 会 TypeError）。而直接用
      // `find.byType(Scrollable).first` 会命中星期 chips 那条
      // SingleChildScrollView（排在前面），滚错地方报 Bad state: No element。
      // 用 descendant 精确锁定到条目列表内部的 Scrollable。
      final tile = find.text(orphan.first.title);
      await tester.scrollUntilVisible(
        tile,
        150,
        scrollable: find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pump();
      expect(tile, findsWidgets, reason: '未收录的条目也要展示');
      expect(find.text('本站未收录，仅展示档期信息'), findsWidgets,
          reason: '不可点的条目要说明原因，否则用户以为界面坏了');

      // 关键：点了不跳转。
      await tester.tap(tile.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('详情'), findsNothing,
          reason: '没有 work_id 就跳不到详情页');
      expect(tester.takeException(), isNull);
    });

    testWidgets('只有一个季度时不显示切换下拉', (tester) async {
      final page = _loadSchedule('real_schedule');
      // 造一个「只有单季度」的响应：保留数据，但 seasons 只留一个。
      final single = SchedulePageData(
        season: page.season,
        seasons: [if (page.season != null) page.season!],
        groups: page.groups,
      );
      final container = ProviderContainer(
        overrides: [
          ...authOverrides(),
          appInitialLocationProvider.overrideWithValue(RoutePaths.schedule),
          scheduleDataSourceProvider.overrideWithValue(
            _FixtureScheduleSource(single),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(scheduleSeasonProvider.notifier).select(null);
      await pumpApp(tester, container);

      expect(find.byTooltip('切换季度'), findsNothing,
          reason: '孤零零的下拉箭头会让人以为还有别的季度可看');
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

  group('封面三态（契约 6.3）', () {
    // 三态的区别是可观察的，不必靠人眼：
    // - 加载中   → 纯色块（`surfaceContainerHighest`），**无渐变、无文字**；
    // - 没有封面 → 品牌色渐变 + 作品首字；
    // - 加载失败 → 与「没有封面」同款（契约不允许出现破图）。
    // 「加载中」必须和「本来就没有」区分开，否则用户会以为作品缺图。
    //
    // ⚠️ 为什么直接测 `CoverImage.loadingFallback` / `CoverImage.errorFallback`
    // 而不是等图片真的加载/失败：
    // `cached_network_image` 走 `flutter_cache_manager` 自己的 HTTP 栈，
    // 不受 flutter_test 的 400 拦截影响；真实请求在 fake async 下不推进，
    // 错误回调永远不来（实测挂 12 秒仍停在加载态；连非法 URL 也一样）。
    // 换句话说「加载中」「加载失败」在 widget test 里都**不可自然触发**。
    // 所以把这两个回调提成公开方法，直接测它们渲染出什么——
    // 测的仍是我们的代码（回调内容是产品决定的），而不是插件的时序。

    Widget wrap(Widget child) => MaterialApp(
          home: Scaffold(body: Center(child: child)),
        );

    /// 指定 widget 区域里有没有渐变（品牌色占位层才有）。
    ///
    /// [root] 传 `null` 表示整棵树——`CoverImage.loadingFallback` 这类
    /// 单独渲染时，树里并没有 [CoverImage] 本身，用它当根会匹配不到。
    bool hasGradient(WidgetTester tester, [Finder? root]) {
      final boxes = tester
          .widgetList<DecoratedBox>(
            root == null
                ? find.byType(DecoratedBox)
                : find.descendant(of: root, matching: find.byType(DecoratedBox)),
          )
          .toList();
      return boxes.any(
        (b) => b.decoration is BoxDecoration &&
            (b.decoration as BoxDecoration).gradient != null,
      );
    }

    testWidgets('没有封面（url 为 null）：渐变 + 首字占位', (tester) async {
      await tester.pumpWidget(
        wrap(const CoverImage(url: null, placeholderLabel: '异')),
      );

      expect(find.text('异'), findsOneWidget, reason: '要显示作品首字');
      expect(
        hasGradient(tester, find.byType(CoverImage)),
        isTrue,
        reason: '占位层要有品牌色渐变',
      );
    });

    testWidgets('加载中：纯骨架，没有渐变也没有文字', (tester) async {
      await tester.pumpWidget(
        wrap(CoverImage.loadingFallback(width: 64, height: 88)),
      );

      expect(find.text('异'), findsNothing, reason: '加载中没有首字');
      expect(
        hasGradient(tester),
        isFalse,
        reason: '加载中只画骨架，不画渐变',
      );
      // 骨架是纯色块：没有任何文字，也没有任何图片。
      expect(find.byType(Text), findsNothing);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('加载失败：回落到占位图（不出现破图）', (tester) async {
      await tester.pumpWidget(
        wrap(
          CoverImage.errorFallback(
            width: 64,
            height: 88,
            label: '异',
          ),
        ),
      );

      expect(find.text('异'), findsOneWidget,
          reason: '加载失败要回落到占位图（契约 6.3：不得显示报错图）');
      // 破图的表现是图片组件还在树上但解码失败——这里不该有裸 Image。
      expect(find.byType(Image), findsNothing);
      expect(
        hasGradient(tester),
        isTrue,
        reason: '失败态与无封面态同款，也是品牌色占位层',
      );
    });

    testWidgets('加载中与「没有封面」长得不一样（这是三态的意义）', (tester) async {
      // 先取「没有封面」那态。
      await tester.pumpWidget(
        wrap(const CoverImage(url: null, placeholderLabel: '异')),
      );
      final noCoverHasGradient = hasGradient(tester, find.byType(CoverImage));
      final noCoverHasLabel = find.text('异').evaluate().isNotEmpty;

      // 再取「加载中」那态。
      await tester.pumpWidget(
        wrap(CoverImage.loadingFallback(width: 64, height: 88)),
      );
      final loadingHasGradient = hasGradient(tester);
      final loadingHasLabel = find.text('异').evaluate().isNotEmpty;

      expect(noCoverHasGradient, isTrue);
      expect(noCoverHasLabel, isTrue);
      expect(loadingHasGradient, isFalse,
          reason: '两态必须能区分，否则「正在加载」会被误读成「没有封面」');
      expect(loadingHasLabel, isFalse,
          reason: '两态必须能区分，否则「正在加载」会被误读成「没有封面」');
    });

    testWidgets('加载失败与「没有封面」走同一条渲染路径（契约 6.3 不许破图）', (tester) async {
      // 这两态在实现上是同一段代码：
      //   没有封面 → errorFallback(label: placeholderLabel)
      //   加载失败 → errorWidget → errorFallback(label: placeholderLabel)
      // 所以「失败时显示占位图而不是破图」这条契约，由「没有封面」那条守住；
      // 这里断言的是**两者渲染出的 widget 树一致**——
      // 万一有人把 errorWidget 改成别的（比如直接返回 Image），这条会红。
      await tester.pumpWidget(
        wrap(const CoverImage(url: null, placeholderLabel: '异')),
      );
      final noCoverTree = tester
          .widgetList(find.byType(Text))
          .map((t) => (t as Text).data)
          .toList();

      await tester.pumpWidget(
        wrap(
          CoverImage.errorFallback(width: 64, height: 88, label: '异'),
        ),
      );
      final failedLikeTree = tester
          .widgetList(find.byType(Text))
          .map((t) => (t as Text).data)
          .toList();

      expect(noCoverTree, failedLikeTree,
          reason: '加载失败态必须与无封面态渲染同样的内容（契约 6.3：不得显示破图）');
      expect(noCoverTree, contains('异'),
          reason: '占位层显示作品首字');
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
