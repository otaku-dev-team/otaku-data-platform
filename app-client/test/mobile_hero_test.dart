import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/app.dart';
import 'package:otaku_app/core/platform_info.dart';
import 'package:otaku_app/core/router/app_router.dart';
import 'package:otaku_app/core/router/route_paths.dart';
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
import 'package:otaku_app/features/reminders/reminder_scheduler.dart';
import 'package:otaku_app/features/reminders/reminder_service.dart';

import 'support/test_overrides.dart';

/// 手机端两个新头图的回归测试。
///
/// 这两个组件在 `PlatformInfo.isDesktop` 为真时直接返回 `SizedBox.shrink()`，
/// 而单测跑在 Windows 上默认就是桌面——不显式切手机平台，测试等于什么都没验。
const String _heroTitle = '测试高分作品';
const SourceRating _heroRating = SourceRating(
  value: 9.5,
  scale: '0-10',
  source: 'bangumi',
);

class _HeroWorkSource implements WorkDataSource {
  @override
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    WorkSort sort = WorkSort.id,
    int page = 1,
    int pageSize = 20,
    List<String>? tags,
    int? year,
  }) async => const PagedResult<WorkSummary>(
    items: [
      WorkSummary(
        workId: 'W-hero',
        workType: WorkType.anime,
        title: _heroTitle,
        releaseYear: 2024,
        mainRating: _heroRating,
        source: 'bangumi',
      ),
    ],
    total: 1,
    page: 1,
    pageSize: 20,
    totalPages: 1,
  );

  @override
  Future<Work> fetchDetail(String workId) async => const Work(
    workId: 'W-hero',
    workType: WorkType.anime,
    title: _heroTitle,
    summary: '这是一段测试简介。',
    releaseYear: 2024,
    tags: ['科幻', '冒险'],
    mainRating: _heroRating,
    source: 'bangumi',
  );

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
  }) async => const PagedResult<ArticleSummary>(
    items: [],
    total: 0,
    page: 1,
    pageSize: 20,
    totalPages: 0,
  );

  @override
  Future<ArticleDetail> fetchDetail(String articleId) async =>
      throw UnimplementedError();

  @override
  Future<List<ArticleCategory>> fetchCategories() async => const [];
}

class _EmptyScheduleSource implements ScheduleDataSource {
  @override
  Future<SchedulePageData> fetchSchedule({String? season}) async =>
      SchedulePageData(season: null, seasons: const [], groups: const []);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget appAt(String location) {
    return ProviderScope(
      overrides: [
        ...authOverrides(),
        appInitialLocationProvider.overrideWithValue(location),
        // 切到手机平台后提醒排程会走真插件（要平台通道），单测里调不了。
        reminderSchedulerProvider.overrideWithValue(
          const NoopReminderScheduler(),
        ),
        workDataSourceProvider.overrideWithValue(_HeroWorkSource()),
        articleDataSourceProvider.overrideWithValue(_EmptyArticleSource()),
        scheduleDataSourceProvider.overrideWithValue(_EmptyScheduleSource()),
      ],
      child: const OtakuApp(),
    );
  }

  /// 手机尺寸 + 手机平台。头图只在这个形态下渲染。
  void usePhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    PlatformInfo.desktopOverride = false;
    addTearDown(tester.view.reset);
    addTearDown(PlatformInfo.resetOverride);
  }

  testWidgets('首页手机端出「高分精选」大图卡，点进去到详情', (tester) async {
    usePhone(tester);
    await tester.pumpWidget(appAt(RoutePaths.home));
    await tester.pumpAndSettle();

    expect(find.text('高分精选'), findsOneWidget);
    // 头图 + 下方「高分作品」横排都可能出现这条标题，至少一次即可。
    expect(find.text(_heroTitle), findsWidgets);

    await tester.tap(find.text('高分精选'));
    await tester.pumpAndSettle();
    expect(find.text('作品详情'), findsOneWidget);
  });

  testWidgets('详情页手机端出沉浸式头图，且不挂主导航', (tester) async {
    usePhone(tester);
    await tester.pumpWidget(appAt(RoutePaths.workDetail('W-hero')));
    await tester.pumpAndSettle();

    expect(find.text(_heroTitle), findsOneWidget);
    expect(find.textContaining('动画'), findsWidgets);
    // 详情是列表的子页，不该有底栏。
    expect(find.byType(NavigationBar), findsNothing);
  });
}
