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
import 'package:otaku_app/data/models/work.dart';
import 'package:otaku_app/data/models/work_sort.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/data/repositories/article_repository.dart';
import 'package:otaku_app/data/repositories/schedule_repository.dart';
import 'package:otaku_app/data/repositories/work_repository.dart';
import 'package:otaku_app/features/reminders/reminder_scheduler.dart';
import 'package:otaku_app/features/reminders/reminder_service.dart';
import 'package:otaku_app/shared/widgets/main_nav_destination.dart';

import 'support/test_overrides.dart';

/// 三个数据源的空实现。
///
/// 不能用 Mock 数据源：Mock 内部用 `Timer` 做延迟，`pumpAndSettle` 之后
/// 仍有未排空的定时器，widget 测试会以「Pending timers」失败。
/// 这条测试只关心导航，数据给空即可。
class _EmptyWorkSource implements WorkDataSource {
  @override
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    WorkSort sort = WorkSort.id,
    int page = 1,
    int pageSize = 20,
    List<String>? tags,
    int? year,
  }) async => PagedResult<WorkSummary>(
    items: [],
    total: 0,
    page: 1,
    pageSize: 20,
    totalPages: 0,
  );

  @override
  Future<Work> fetchDetail(String workId) async => throw UnimplementedError();

  @override
  Future<RelatedWorks> fetchRelated(String workId, {int limit = 6}) async =>
      RelatedWorks(basisTags: const [], items: const []);
}

class _EmptyArticleSource implements ArticleDataSource {
  @override
  Future<PagedResult<ArticleSummary>> fetchArticles({
    String? category,
    int page = 1,
    int pageSize = 20,
  }) async => PagedResult<ArticleSummary>(
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

/// 手机端主导航（`docs/flutter-lead-plan.md` §6「两端差异清单」第一行：
/// 主导航 手机 `NavigationBar` / 桌面 `NavigationRail`）。
///
/// 这组测试钉的是**结构与跳转**，不钉外观：
/// - 底栏出现在手机形态、且桌面形态下不出现；
/// - 五项顺序与桌面侧栏一致（两端共用 [MainNavDestination]）；
/// - 点某一项真的跳到对应路由。
///
/// 走查背景（2026-10-28 模拟器）：手机端此前**完全没有主导航**，
/// `DesktopNavShell` 在非桌面端直接返回 child，五个主页面只能靠 AppBar 里
/// 零散的图标互跳——收藏页在首页上根本没有入口。
///
/// 用真实的 [OtakuApp] 而不是自建 GoRouter：`MaterialApp.router` 的 `builder`
/// 在 router **之上**，那里 `GoRouter.maybeOf` 拿到的是 null，测不到
/// 生产形态（页面 Scaffold 在 router 之下，底栏能拿到 router）。
///
/// 还要用 [PlatformInfo.desktopOverride] 切平台：单测跑在 Windows 上，
/// `Platform.isWindows` 恒为 true，不覆盖就永远验不到手机那一半。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget appAt(String location) {
    return ProviderScope(
      overrides: [
        ...authOverrides(),
        appInitialLocationProvider.overrideWithValue(location),
        // 切到「手机平台」后，提醒排程会走真插件（要平台通道），
        // 单测里调不了。换成空实现——这条测试只关心导航。
        reminderSchedulerProvider.overrideWithValue(
          const NoopReminderScheduler(),
        ),
        // 用空数据源而不是 Mock：Mock 内部的延迟定时器排不干净，
        // widget 测试会以「Pending timers」失败。
        workDataSourceProvider.overrideWithValue(_EmptyWorkSource()),
        articleDataSourceProvider.overrideWithValue(_EmptyArticleSource()),
        scheduleDataSourceProvider.overrideWithValue(_EmptyScheduleSource()),
      ],
      child: const OtakuApp(),
    );
  }

  /// 手机尺寸 + 手机平台。底栏是手机形态才有的东西，两样都得给。
  void usePhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    PlatformInfo.desktopOverride = false;
    addTearDown(tester.view.reset);
    addTearDown(PlatformInfo.resetOverride);
  }

  /// 桌面尺寸 + 桌面平台。
  void useDesktop(WidgetTester tester) {
    tester.view.physicalSize = const Size(2560, 1440);
    tester.view.devicePixelRatio = 1;
    PlatformInfo.desktopOverride = true;
    addTearDown(tester.view.reset);
    addTearDown(PlatformInfo.resetOverride);
  }

  group('主导航目的地', () {
    test('五项顺序：首页 / 作品库 / 资讯 / 收藏 / 新番', () {
      expect(MainNavDestination.values.map((d) => d.path).toList(), [
        RoutePaths.home,
        RoutePaths.contents,
        RoutePaths.articles,
        RoutePaths.collections,
        RoutePaths.schedule,
      ]);
    });

    test('首页按精确相等判定，不被其它路径误命中', () {
      // `/works`.startsWith('/') 为真——首页若用 startsWith，
      // 站在作品库里也会被算成「当前在首页」。
      expect(
        MainNavDestination.fromLocation(RoutePaths.contents),
        MainNavDestination.contents,
      );
      expect(MainNavDestination.fromLocation('/'), MainNavDestination.home);
      expect(
        MainNavDestination.fromLocation('/collections'),
        MainNavDestination.collections,
      );
    });

    test('子路由归到它的父项，详情页算作品库', () {
      expect(
        MainNavDestination.fromLocation('/works/W-1'),
        MainNavDestination.contents,
      );
      expect(
        MainNavDestination.fromLocation('/articles/a-1'),
        MainNavDestination.articles,
      );
    });

    test('设置页不在主导航里', () {
      expect(MainNavDestination.fromLocation(RoutePaths.settings), isNull);
    });

    test('底栏用简称、侧栏用全称提示——避免与 AppBar 标题重名', () {
      // 作品库页的 AppBar 标题是「作品库」；底栏若也写「作品库」，
      // 同一屏就有两个同名文本，`find.text('作品库')` 会一次命中两个。
      final contents = MainNavDestination.values[1];
      expect(contents.tooltip, '作品库');
      expect(contents.label, '浏览');
    });
  });

  group('手机端底栏', () {
    testWidgets('首页出底栏，五个目的地齐全', (tester) async {
      usePhone(tester);

      await tester.pumpWidget(appAt(RoutePaths.home));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsOneWidget);
      // 用图标类型判定，不用文字——底栏的文字标签默认只有选中项显示。
      //
      // ⚠️ 必须限定在底栏**内部**找：作品库 AppBar 也有一个同款书签图标
      // （`contents_page.dart` 的收藏入口），整页找会命中两个，
      // 于是这条断言变成「首页有几个书签图标」而不是「底栏有五个目的地」。
      final inBar = find.descendant(
        of: find.byType(NavigationBar),
        matching: find.byIcon(Icons.home_rounded),
      );
      expect(inBar, findsOneWidget);
      for (final icon in [
        Icons.grid_view_outlined,
        Icons.newspaper_outlined,
        Icons.bookmark_border_rounded,
        Icons.calendar_today_outlined,
      ]) {
        expect(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.byIcon(icon),
          ),
          findsOneWidget,
          reason: '底栏每个目的地各一个（$icon）',
        );
      }
    });

    testWidgets('当前页对应的那一项是选中态', (tester) async {
      usePhone(tester);

      await tester.pumpWidget(appAt(RoutePaths.collections));
      await tester.pumpAndSettle();

      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(
        bar.selectedIndex,
        MainNavDestination.values.indexOf(MainNavDestination.collections),
      );
    });

    testWidgets('点底栏真的跳到对应路由', (tester) async {
      usePhone(tester);

      await tester.pumpWidget(appAt(RoutePaths.home));
      await tester.pumpAndSettle();

      // 起点是首页：不再断言 AppBar 标题是「首页」——首页改版后标题换成了
      // 品牌行（标识 + Otaku + 日期），钉标题等于钉品牌样式，一改版就红。
      // 底栏的选中项才是「现在在首页」这件事的可靠表达。
      final startBar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(startBar.selectedIndex, 0, reason: '起点在首页（底栏第一项）');

      // 收藏页此前在手机上**完全没有入口**（首页上没有，作品库 AppBar 里有个
      // 书签图标）——这条钉的就是「从首页一步能到收藏」。
      // 同样限定在底栏内：否则点到的可能是作品库 AppBar 那个书签。
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.byIcon(Icons.bookmark_border_rounded),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, '我的收藏'), findsOneWidget);
    });

    testWidgets('详情页不挂底栏（子路由，正文不被压掉）', (tester) async {
      usePhone(tester);

      await tester.pumpWidget(appAt(RoutePaths.contents));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('桌面形态不挂底栏（桌面是侧栏，不是两套主导航）', (tester) async {
      useDesktop(tester);

      await tester.pumpWidget(appAt(RoutePaths.home));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(NavigationRail), findsOneWidget);
    });
  });
}
