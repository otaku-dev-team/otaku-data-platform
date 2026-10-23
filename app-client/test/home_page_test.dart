import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/app.dart';
import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/data/datasources/article_data_source.dart';
import 'package:otaku_app/data/datasources/schedule_data_source.dart';
import 'package:otaku_app/data/datasources/work_data_source.dart';
import 'package:otaku_app/data/models/article.dart';
import 'package:otaku_app/data/models/paged_result.dart';
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
import 'package:otaku_app/features/article/article_card.dart';
import 'package:otaku_app/features/contents/contents_controller.dart';
import 'package:otaku_app/features/contents/contents_page.dart';
import 'package:otaku_app/shared/widgets/compact_work_card.dart';
import 'package:otaku_app/features/home/home_controller.dart';

import 'support/test_overrides.dart';

const _rating = SourceRating(value: 8.8, scale: '0-10', source: 'bangumi');

class _FakeWorkSource implements WorkDataSource {
  _FakeWorkSource({this.error});

  /// 非 null 时每次取列表都抛它。用 `ApiException` 而不是普通异常：
  /// 仓储只会把这类错误收敛成界面认识的形状。
  final ApiException? error;

  int calls = 0;

  static const items = [
    WorkSummary(
      workId: 'W-1',
      workType: WorkType.anime,
      title: '高分甲',
      releaseYear: 2020,
      mainRating: _rating,
    ),
    WorkSummary(
      workId: 'W-2',
      workType: WorkType.comic,
      title: '高分乙',
      mainRating: _rating,
    ),
  ];

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
    if (error != null) throw error!;
    return PagedResult<WorkSummary>(
      items: items,
      total: items.length,
      page: 1,
      pageSize: pageSize,
      totalPages: 1,
    );
  }

  @override
  Future<Work> fetchDetail(String workId) async => throw UnimplementedError();

  @override
  Future<RelatedWorks> fetchRelated(String workId, {int limit = 6}) async =>
      const RelatedWorks(basisTags: [], items: []);
}

class _FakeArticleSource implements ArticleDataSource {
  static const items = [
    ArticleSummary(
      articleId: 'A-1',
      title: '资讯一',
      summary: '摘要一',
      category: '动画',
    ),
    ArticleSummary(articleId: 'A-2', title: '资讯二'),
    ArticleSummary(articleId: 'A-3', title: '资讯三'),
  ];

  @override
  Future<PagedResult<ArticleSummary>> fetchArticles({
    String? category,
    int page = 1,
    int pageSize = 20,
  }) async {
    return PagedResult<ArticleSummary>(
      items: items.take(pageSize).toList(growable: false),
      total: items.length,
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

class _FakeScheduleSource implements ScheduleDataSource {
  _FakeScheduleSource({this.error});

  final ApiException? error;

  /// 只在周一放一条、其余天留空：首页「本日新番」按星期取组的语义
  /// 靠这两条数据就能验出来（周一有内容、周二空）。
  static const _page = SchedulePageData(
    season: '202610',
    seasons: ['202610'],
    groups: [
      ScheduleGroup(
        weekday: 1,
        label: '周一',
        items: [
          ScheduleEntry(
            scheduleId: 'S-1',
            title: '周一新番甲',
            weekday: 1,
            broadcastTime: '22:00',
            workType: '小说改编动画',
          ),
        ],
      ),
      ScheduleGroup(weekday: 2, label: '周二', items: []),
      ScheduleGroup(weekday: 3, label: '周三', items: []),
      ScheduleGroup(weekday: 4, label: '周四', items: []),
      ScheduleGroup(weekday: 5, label: '周五', items: []),
      ScheduleGroup(weekday: 6, label: '周六', items: []),
      ScheduleGroup(weekday: 7, label: '周日', items: []),
    ],
  );

  @override
  Future<SchedulePageData> fetchSchedule({String? season}) async {
    if (error != null) throw error!;
    return _page;
  }
}

const _networkError = ApiException(
  code: ApiErrorCode.network,
  message: '网络不可用',
);

void main() {
  Widget app({
    WorkDataSource? work,
    ArticleDataSource? article,
    ScheduleDataSource? schedule,
    int weekday = 1,
  }) {
    return ProviderScope(
      overrides: [
        // 首页右上角有账号入口，任何 pump 到 OtakuApp 的用例都要给内存令牌。
        ...authOverrides(),
        workDataSourceProvider.overrideWithValue(work ?? _FakeWorkSource()),
        articleDataSourceProvider.overrideWithValue(
          article ?? _FakeArticleSource(),
        ),
        scheduleDataSourceProvider.overrideWithValue(
          schedule ?? _FakeScheduleSource(),
        ),
        // 「今天」固定成周一：否则这条用例只在星期一通过。
        homeTodayWeekdayProvider.overrideWithValue(weekday),
      ],
      child: const OtakuApp(),
    );
  }

  /// 首页四块是纵向长内容，默认 800×600 的测试窗口装不下第四块——
  /// 横向列表之外的区块是懒构建的，「最新资讯」不滚到就不会存在，
  /// 断言必然找不到。所以把这个用例的窗口放大，而不是去模拟滚动。
  Future<void> pumpApp(WidgetTester tester, Widget widget) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(widget);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('落地页就是首页，四块内容都在', (tester) async {
    await pumpApp(tester, app());

    // 侧栏也有一个「首页」标签（`labelType: none` 不画出来，但仍在树里），
    // 所以标题要限定在 AppBar 上找，否则会一次命中两个。
    expect(find.widgetWithText(AppBar, '首页'), findsOneWidget);
    expect(find.text('分类浏览'), findsOneWidget);
    expect(find.text('本日新番'), findsOneWidget);
    expect(find.text('高分作品'), findsOneWidget);
    expect(find.text('最新资讯'), findsOneWidget);

    // 三块的真实内容：1 条档期、2 张海报卡、3 张资讯卡。
    expect(find.text('周一新番甲'), findsOneWidget);
    expect(find.byType(CompactWorkCard), findsNWidgets(2));
    expect(find.byType(ArticleCard), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机宽度（390）下首屏不溢出', (tester) async {
    // 这条不放大窗口，就按一台常见手机的尺寸看首屏：
    // 卡片是横向滚动的，窄屏最容易把标题、评分行挤到卡片外面。
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('分类浏览'), findsOneWidget);
    expect(find.text('本日新番'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('本日新番取的是「今天」那一组，不是全部', (tester) async {
    await pumpApp(tester, app(weekday: 1));
    expect(find.text('周一新番甲'), findsOneWidget);

    await pumpApp(tester, app(weekday: 2));
    // 周二那组是空的：说「今天没有排期」，而不是把区块整块藏掉——
    // 藏掉之后用户分不清「今天没番」和「页面坏了」。
    expect(find.text('周一新番甲'), findsNothing);
    expect(find.text('今天没有排期'), findsOneWidget);
  });

  testWidgets('某一块失败不拖垮整页，其余三块照常渲染', (tester) async {
    await pumpApp(
      tester,
      app(schedule: _FakeScheduleSource(error: _networkError)),
    );

    // 失败的是档期：区块内给一条重试，页面不变成整页错误态。
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('本日新番'), findsOneWidget);
    expect(find.text('高分作品'), findsOneWidget);
    expect(find.byType(CompactWorkCard), findsNWidgets(2));
    expect(find.byType(ArticleCard), findsNWidgets(3));
  });

  testWidgets('作品区块失败时，资讯与档期照常渲染', (tester) async {
    await pumpApp(tester, app(work: _FakeWorkSource(error: _networkError)));

    expect(find.text('重试'), findsOneWidget);
    expect(find.text('周一新番甲'), findsOneWidget);
    expect(find.byType(ArticleCard), findsNWidgets(3));
    expect(find.byType(CompactWorkCard), findsNothing);
  });

  testWidgets('点分类入口跳到列表页', (tester) async {
    await pumpApp(tester, app());

    // 「漫画」在首页出现两次（分类入口 + 高分卡片的类型标签），
    // 必须限定在 chip 上点，否则点到卡片里去了。
    await tester.tap(find.widgetWithText(ActionChip, '漫画'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(ContentsPage), findsOneWidget);
    expect(find.text('作品库'), findsOneWidget);
  });

  testWidgets('「高分作品 · 查看全部」带着评分排序进列表', (tester) async {
    await pumpApp(tester, app());

    // 三个区块都有「查看全部」，顺序是 本日新番 / 高分作品 / 最新资讯。
    final moreButtons = find.text('查看全部');
    expect(moreButtons, findsNWidgets(3));
    await tester.tap(moreButtons.at(1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(ContentsPage), findsOneWidget);
    // 排序控件只在 tooltip 里写当前项，界面上没有可断言的文字，
    // 所以直接读控件的状态：确认「不只跳了页，排序也带过去了」。
    final sortMenu = tester.widget<PopupMenuButton<WorkSort>>(
      find.byType(PopupMenuButton<WorkSort>),
    );
    expect(sortMenu.initialValue, WorkSort.rating);
  });

  group('ContentsFilterController 的首页入口', () {
    test('showType 只保留类型，清掉搜索 / 标签 / 排序', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(contentsFilterProvider.notifier);

      controller.selectTag('科幻');
      controller.selectSort(WorkSort.rating);
      controller.search('eva');

      controller.showType(WorkType.anime);

      final filter = container.read(contentsFilterProvider);
      expect(filter.type, WorkType.anime);
      expect(filter.tag, isNull);
      expect(filter.query, isEmpty);
      expect(filter.sort, WorkSort.id);
    });

    test('showTopRated 只保留排序', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(contentsFilterProvider.notifier);

      controller.selectType(WorkType.game);
      controller.selectTag('科幻');

      controller.showTopRated();

      final filter = container.read(contentsFilterProvider);
      expect(filter.sort, WorkSort.rating);
      expect(filter.type, isNull);
      expect(filter.tag, isNull);
    });
  });
}
