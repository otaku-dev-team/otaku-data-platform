import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/core/storage/memory_recent_views_store.dart';
import 'package:otaku_app/core/storage/recent_views_provider.dart';
import 'package:otaku_app/data/models/source_rating.dart';
import 'package:otaku_app/data/models/work.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/features/recent/recent_history_page.dart';
import 'package:otaku_app/features/recent/recent_views_controller.dart';

import 'support/test_overrides.dart';

Work _work(String workId, {String? title}) {
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

/// 今天中午。用固定的「正午」而不是 `DateTime.now()` 本身当锚点：
/// 在凌晨或深夜跑测试时，`now.subtract(Duration(days: 1))` 可能跨出「昨天」的边界，
/// 让分组断言随运行时刻飘。
DateTime _todayNoon() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day, 12);
}

void main() {
  /// 起一个只装了这一页的最小 App，返回 container 方便预置历史。
  Future<ProviderContainer> pumpPage(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        ...authOverrides(),
        recentViewsStoreProvider.overrideWithValue(InMemoryRecentViewsStore()),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: RecentHistoryPage()),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('没有历史时显示空态，不显示清空按钮', (tester) async {
    await pumpPage(tester);

    expect(find.text('还没有浏览记录'), findsOneWidget);
    expect(find.byTooltip('清空'), findsNothing);
  });

  testWidgets('按今天 / 昨天 / 更早分组，各段只放自己那几条', (tester) async {
    final container = await pumpPage(tester);
    final today = _todayNoon();

    container
        .read(recentViewsProvider.notifier)
        .record(_work('T', title: '今天看的'), at: today);
    container
        .read(recentViewsProvider.notifier)
        .record(_work('Y', title: '昨天看的'), at: today.subtract(const Duration(days: 1)));
    container
        .read(recentViewsProvider.notifier)
        .record(_work('E', title: '三天前看的'), at: today.subtract(const Duration(days: 3)));
    await tester.pumpAndSettle();

    expect(find.text('今天'), findsOneWidget);
    expect(find.text('昨天'), findsOneWidget);
    expect(find.text('更早'), findsOneWidget);

    expect(find.text('今天看的'), findsOneWidget);
    expect(find.text('昨天看的'), findsOneWidget);
    expect(find.text('三天前看的'), findsOneWidget);
  });

  testWidgets('某一段为空时，那一段的标题不出现', (tester) async {
    final container = await pumpPage(tester);

    // 只有今天这一条，昨天与更早都不该出现标题。
    container
        .read(recentViewsProvider.notifier)
        .record(_work('T', title: '今天看的'), at: _todayNoon());
    await tester.pumpAndSettle();

    expect(find.text('今天'), findsOneWidget);
    expect(find.text('昨天'), findsNothing);
    expect(find.text('更早'), findsNothing);
  });

  testWidgets('左滑删掉一条，并可以撤销回原位', (tester) async {
    final container = await pumpPage(tester);
    final today = _todayNoon();

    container
        .read(recentViewsProvider.notifier)
        .record(_work('A', title: '第一条'), at: today.subtract(const Duration(minutes: 3)));
    container
        .read(recentViewsProvider.notifier)
        .record(_work('B', title: '第二条'), at: today.subtract(const Duration(minutes: 1)));
    await tester.pumpAndSettle();

    // record 是置顶的，列表顺序是 [第二条, 第一条]。
    expect(container.read(recentViewsProvider).map((e) => e.workId), ['B', 'A']);

    await tester.drag(find.text('第二条'), const Offset(-600, 0));
    await tester.pumpAndSettle();

    expect(container.read(recentViewsProvider).map((e) => e.workId), ['A']);
    expect(find.text('第二条'), findsNothing);
    expect(find.text('已删除「第二条」'), findsOneWidget);

    // 撤销：放回原来的位置（第一条上面），而不是置顶之后又变成第二条在前。
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();

    expect(container.read(recentViewsProvider).map((e) => e.workId), ['B', 'A']);
    expect(find.text('第二条'), findsOneWidget);
  });

  testWidgets('清空要二次确认，取消后记录还在', (tester) async {
    final container = await pumpPage(tester);

    container.read(recentViewsProvider.notifier).record(_work('A'), at: _todayNoon());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();
    expect(find.text('清空最近浏览？'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(find.text('清空最近浏览？'), findsNothing);
    expect(container.read(recentViewsProvider), hasLength(1));
  });
}
