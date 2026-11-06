import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:otaku_app/core/platform_info.dart';
import 'package:otaku_app/core/router/route_paths.dart';
import 'package:otaku_app/core/theme/app_theme.dart';
import 'package:otaku_app/data/datasources/collection_data_source.dart';
import 'package:otaku_app/data/models/collection_entry.dart';
import 'package:otaku_app/data/models/collection_state.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/data/repositories/collection_repository.dart';
import 'package:otaku_app/features/collection/collection_page.dart';
import 'package:otaku_app/shared/widgets/collection_status_menu.dart';

import 'support/test_overrides.dart';

class _CollectionSource implements CollectionDataSource {
  _CollectionSource({bool empty = false})
    : items = empty
          ? []
          : [
              CollectionEntry(
                workId: 'W-1',
                title: '测试收藏作品',
                workType: WorkType.anime,
                status: CollectionStatus.watching,
              ),
            ];

  final List<CollectionEntry> items;
  int listCalls = 0;
  int removeCalls = 0;
  Completer<void>? removeGate;

  @override
  Future<List<CollectionEntry>> fetchAll({CollectionStatus? status}) async {
    listCalls++;
    return [
      for (final item in items)
        if (status == null || item.status == status) item,
    ];
  }

  @override
  Future<void> remove(String workId) async {
    removeCalls++;
    await removeGate?.future;
    items.removeWhere((item) => item.workId == workId);
  }

  @override
  Future<CollectionState> fetchState(String workId) =>
      throw UnimplementedError();

  @override
  Future<CollectionState> add(String workId, {CollectionStatus? status}) =>
      throw UnimplementedError();

  @override
  Future<CollectionState> updateStatus(
    String workId,
    CollectionStatus? status,
  ) => throw UnimplementedError();
}

void main() {
  Future<void> pumpCollection(
    WidgetTester tester,
    _CollectionSource source, {
    bool desktop = false,
    double width = 390,
    double textScale = 1,
  }) async {
    PlatformInfo.desktopOverride = desktop;
    addTearDown(PlatformInfo.resetOverride);
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: RoutePaths.collections,
      routes: [
        GoRoute(
          path: RoutePaths.collections,
          builder: (_, _) => const CollectionPage(),
        ),
        GoRoute(
          path: RoutePaths.contents,
          builder: (_, _) => const Scaffold(body: Text('作品库目的页')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...authOverrides(token: signedInToken),
          collectionDataSourceProvider.overrideWithValue(source),
        ],
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
  }

  testWidgets('手机取消收藏可触达，放弃确认保留作品和观看状态', (tester) async {
    final source = _CollectionSource();
    await pumpCollection(tester, source);
    final button = find.widgetWithIcon(
      IconButton,
      Icons.bookmark_remove_rounded,
    );
    final size = tester.getSize(button);
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('取消收藏？'), findsOneWidget);
    expect(source.removeCalls, 0);
    await tester.tap(find.text('保留收藏'));
    await tester.pumpAndSettle();
    expect(source.removeCalls, 0);
    expect(source.items.single.status, CollectionStatus.watching);
    expect(find.text('测试收藏作品'), findsOneWidget);
  });

  testWidgets('确认后只发一次删除，请求期间禁用卡片写操作', (tester) async {
    final source = _CollectionSource()..removeGate = Completer<void>();
    await pumpCollection(tester, source);
    final button = find.widgetWithIcon(
      IconButton,
      Icons.bookmark_remove_rounded,
    );
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '取消收藏'));
    await tester.pumpAndSettle();
    expect(source.removeCalls, 1);
    expect(tester.widget<IconButton>(button).onPressed, isNull);
    expect(
      tester
          .widget<CollectionStatusMenu>(find.byType(CollectionStatusMenu))
          .enabled,
      isFalse,
    );
    expect(find.text('测试收藏作品'), findsOneWidget);
    source.removeGate!.complete();
    await tester.pumpAndSettle();
    expect(source.items, isEmpty);
    expect(find.text('还没有收藏'), findsOneWidget);
    expect(find.text('已取消收藏'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('只有一个收藏也可以下拉刷新', (tester) async {
    final source = _CollectionSource();
    await pumpCollection(tester, source);
    final initialCalls = source.listCalls;
    await tester.drag(find.byType(GridView), const Offset(0, 350));
    await tester.pumpAndSettle();
    expect(source.listCalls, greaterThan(initialCalls));
  });

  testWidgets('空收藏可以下拉刷新并一步去作品库', (tester) async {
    final source = _CollectionSource(empty: true);
    await pumpCollection(tester, source);
    final initialCalls = source.listCalls;
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 350));
    await tester.pumpAndSettle();
    expect(source.listCalls, greaterThan(initialCalls));
    await tester.tap(find.text('去作品库'));
    await tester.pumpAndSettle();
    expect(find.text('作品库目的页'), findsOneWidget);
  });

  testWidgets('状态筛选为空时可以直接回全部收藏', (tester) async {
    final source = _CollectionSource();
    await pumpCollection(tester, source);
    await tester.tap(find.widgetWithText(ChoiceChip, '想看'));
    await tester.pumpAndSettle();
    expect(find.text('没有「想看」的作品'), findsOneWidget);
    await tester.tap(find.text('查看全部收藏'));
    await tester.pumpAndSettle();
    expect(find.text('测试收藏作品'), findsOneWidget);
  });

  testWidgets('320 宽大字号下卡片与取消确认可用', (tester) async {
    await pumpCollection(tester, _CollectionSource(), width: 320, textScale: 2);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('取消收藏'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('保留收藏'));
    await tester.pumpAndSettle();
    expect(find.text('测试收藏作品'), findsOneWidget);
  });

  testWidgets('桌面保留直接取消收藏的操作', (tester) async {
    final source = _CollectionSource();
    await pumpCollection(tester, source, desktop: true, width: 1000);
    await tester.tap(find.byTooltip('取消收藏'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(source.removeCalls, 1);
    expect(source.items, isEmpty);
  });
}
