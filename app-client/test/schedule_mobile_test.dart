import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:otaku_app/core/platform_info.dart';
import 'package:otaku_app/core/router/route_paths.dart';
import 'package:otaku_app/core/theme/app_theme.dart';
import 'package:otaku_app/data/datasources/schedule_data_source.dart';
import 'package:otaku_app/data/models/schedule.dart';
import 'package:otaku_app/data/repositories/schedule_repository.dart';
import 'package:otaku_app/features/schedule/schedule_controller.dart';
import 'package:otaku_app/features/schedule/schedule_page.dart';

import 'support/test_overrides.dart';

class _ScheduleSource implements ScheduleDataSource {
  _ScheduleSource({this.empty = false, this.onlyOldSeason = false});

  final bool empty;
  final bool onlyOldSeason;
  final calls = <String?>[];

  @override
  Future<SchedulePageData> fetchSchedule({String? season}) async {
    calls.add(season);
    return SchedulePageData(
      season: season ?? (onlyOldSeason ? '202607' : '202610'),
      seasons: onlyOldSeason ? const ['202607'] : const ['202610', '202607'],
      groups: empty
          ? const []
          : const [
              ScheduleGroup(
                weekday: 1,
                label: '周一',
                items: [
                  ScheduleEntry(
                    scheduleId: 'S-today',
                    title: '今天的新番',
                    weekday: 1,
                    broadcastTime: '22:30',
                    workId: 'W-today',
                  ),
                ],
              ),
              ScheduleGroup(
                weekday: null,
                label: '待定',
                items: [
                  ScheduleEntry(scheduleId: 'S-unknown', title: '尚未收录的新番'),
                ],
              ),
            ],
    );
  }
}

void main() {
  Future<ProviderContainer> pumpSchedule(
    WidgetTester tester,
    _ScheduleSource source, {
    double width = 390,
    double textScale = 1,
  }) async {
    PlatformInfo.desktopOverride = false;
    addTearDown(PlatformInfo.resetOverride);
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        ...authOverrides(),
        scheduleDataSourceProvider.overrideWithValue(source),
        scheduleTodayProvider.overrideWithValue(DateTime(2026, 11, 2)),
      ],
    );
    addTearDown(container.dispose);
    final router = GoRouter(
      initialLocation: RoutePaths.schedule,
      routes: [
        GoRoute(
          path: RoutePaths.schedule,
          builder: (_, _) => const SchedulePage(),
        ),
        GoRoute(
          path: '${RoutePaths.contents}/:workId',
          builder: (_, _) => const Scaffold(body: Text('作品详情目的页')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('手机显示季度和今天，默认仍是全部，今天快捷只筛本日', (tester) async {
    final source = _ScheduleSource();
    final container = await pumpSchedule(tester, source);
    expect(find.text('2026 年 10 月'), findsOneWidget);
    expect(find.text('周一 · 今天'), findsOneWidget);
    expect(container.read(scheduleWeekdayProvider), ScheduleWeekday.all);
    await tester.tap(find.text('今天'));
    await tester.pumpAndSettle();
    expect(container.read(scheduleWeekdayProvider), ScheduleWeekday.monday);
    expect(find.text('今天的新番'), findsOneWidget);
    expect(find.text('尚未收录的新番'), findsNothing);
    expect(source.calls, [null]);
  });

  testWidgets('从旧季度点今天回到本季度，旧季度不贴今天标记', (tester) async {
    final source = _ScheduleSource();
    final container = await pumpSchedule(tester, source);
    await tester.tap(find.byTooltip('切换季度'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2026 年 7 月'));
    await tester.pumpAndSettle();
    expect(container.read(scheduleSeasonProvider), '202607');
    expect(find.text('周一 · 今天'), findsNothing);
    await tester.tap(find.text('今天'));
    await tester.pumpAndSettle();
    expect(container.read(scheduleSeasonProvider), '202610');
    expect(container.read(scheduleWeekdayProvider), ScheduleWeekday.monday);
    expect(source.calls.last, '202610');
  });

  testWidgets('没有本季数据时不把旧排期当作今天', (tester) async {
    await pumpSchedule(tester, _ScheduleSource(onlyOldSeason: true));
    expect(find.text('今天'), findsNothing);
    expect(find.textContaining('· 今天'), findsNothing);
    expect(find.text('所选季度排期 · 按星期查看'), findsOneWidget);
  });

  testWidgets('320宽双倍字号星期全部可滚动到达，空日可回全部', (tester) async {
    final container = await pumpSchedule(
      tester,
      _ScheduleSource(),
      width: 320,
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    final sunday = find.widgetWithText(ChoiceChip, '周日');
    await tester.ensureVisible(sunday);
    await tester.tap(sunday);
    await tester.pumpAndSettle();
    expect(container.read(scheduleWeekdayProvider), ScheduleWeekday.sunday);
    final all = find.text('查看全部排期');
    await tester.ensureVisible(all);
    await tester.tap(all);
    await tester.pumpAndSettle();
    expect(container.read(scheduleWeekdayProvider), ScheduleWeekday.all);
    expect(tester.takeException(), isNull);
  });

  for (final empty in [true, false]) {
    testWidgets('${empty ? '空排期' : '少量排期'}可以下拉刷新', (tester) async {
      final source = _ScheduleSource(empty: empty);
      await pumpSchedule(tester, source);
      final before = source.calls.length;
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 350));
      await tester.pumpAndSettle();
      expect(source.calls.length, greaterThan(before));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('未收录条目仍不可点击，已收录条目可进入详情', (tester) async {
    await pumpSchedule(tester, _ScheduleSource());
    await tester.ensureVisible(find.text('尚未收录的新番'));
    await tester.tap(find.text('尚未收录的新番'));
    await tester.pumpAndSettle();
    expect(find.text('作品详情目的页'), findsNothing);
    await tester.ensureVisible(find.text('今天的新番'));
    await tester.tap(find.text('今天的新番'));
    await tester.pumpAndSettle();
    expect(find.text('作品详情目的页'), findsOneWidget);
  });
}
