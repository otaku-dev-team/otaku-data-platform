import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/app.dart';
import 'package:otaku_app/core/platform_info.dart';
import 'package:otaku_app/core/router/app_router.dart';
import 'package:otaku_app/core/router/route_paths.dart';
import 'package:otaku_app/data/datasources/collection_mock_data_source.dart';
import 'package:otaku_app/data/datasources/work_data_source.dart';
import 'package:otaku_app/data/models/collection_entry.dart';
import 'package:otaku_app/data/models/collection_state.dart';
import 'package:otaku_app/data/models/paged_result.dart';
import 'package:otaku_app/data/models/related_works.dart';
import 'package:otaku_app/data/models/work.dart';
import 'package:otaku_app/data/models/work_sort.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/data/repositories/collection_repository.dart';
import 'package:otaku_app/data/repositories/work_repository.dart';
import 'package:otaku_app/shared/widgets/collection_status_menu.dart';

import 'support/test_overrides.dart';

const _title = '在遥远星空下寻找归途的少年与少女们的漫长冒险故事';

class _DetailSource implements WorkDataSource {
  @override
  Future<Work> fetchDetail(String workId) async => Work(
    workId: workId,
    workType: WorkType.anime,
    title: _title,
    releaseYear: 2026,
    summary: List.filled(20, '他们踏上了寻找故乡的旅途，每一次相遇都留下新的故事。').join(),
    tags: const ['冒险'],
  );

  @override
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    WorkSort sort = WorkSort.id,
    int page = 1,
    int pageSize = 20,
    List<String>? tags,
    int? year,
  }) async => PagedResult(
    items: const [],
    total: 0,
    page: page,
    pageSize: pageSize,
    totalPages: 0,
  );

  @override
  Future<RelatedWorks> fetchRelated(String workId, {int limit = 6}) async =>
      const RelatedWorks(basisTags: [], items: []);
}

class _Collections extends CollectionMockDataSource {
  _Collections() : super(delay: Duration.zero);
  int removes = 0;
  int stateRequests = 0;
  Completer<void>? removalGate;

  @override
  Future<CollectionState> fetchState(String workId) {
    stateRequests++;
    return super.fetchState(workId);
  }

  @override
  Future<void> remove(String workId) async {
    removes++;
    if (removalGate != null) await removalGate!.future;
    await super.remove(workId);
  }
}

void main() {
  Future<void> pumpDetail(
    WidgetTester tester,
    _Collections source, {
    bool signedIn = true,
    bool desktop = false,
    double width = 390,
    double textScale = 1,
  }) async {
    PlatformInfo.desktopOverride = desktop;
    addTearDown(PlatformInfo.resetOverride);
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...authOverrides(token: signedIn ? signedInToken : null),
          ...tagOverrides(),
          appInitialLocationProvider.overrideWithValue(
            RoutePaths.workDetail('mock-w-001'),
          ),
          workDataSourceProvider.overrideWithValue(_DetailSource()),
          collectionDataSourceProvider.overrideWithValue(source),
        ],
        child: const OtakuApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('手机详情收藏栏固定在底部，滚动正文不会丢失操作', (tester) async {
    await pumpDetail(tester, _Collections());
    final actions = find.byKey(const ValueKey('detail-mobile-actions'));
    final position = tester.getTopLeft(actions);
    expect(find.widgetWithText(FilledButton, '已收藏'), findsOneWidget);
    expect(find.byType(CollectionStatusMenu), findsOneWidget);
    await tester.drag(find.text('简介'), const Offset(0, -450));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(actions), position);
    expect(
      find.widgetWithText(FilledButton, '已收藏').hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机详情取消收藏需确认，取消对话框不清除观看状态', (tester) async {
    final source = _Collections();
    await pumpDetail(tester, source);
    await tester.tap(find.byTooltip('取消收藏'));
    await tester.pumpAndSettle();
    expect(find.text('取消收藏？'), findsOneWidget);
    expect(source.removes, 0);
    await tester.tap(find.text('保留收藏'));
    await tester.pumpAndSettle();
    expect(source.removes, 0);
    expect(
      tester
          .widget<CollectionStatusMenu>(find.byType(CollectionStatusMenu))
          .status,
      CollectionStatus.watching,
    );
    expect(find.widgetWithText(FilledButton, '已收藏'), findsOneWidget);
  });

  testWidgets('确认删除后等待服务端完成，期间禁用收藏与状态操作', (tester) async {
    final source = _Collections()..removalGate = Completer<void>();
    await pumpDetail(tester, source);
    await tester.tap(find.byTooltip('取消收藏'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '取消收藏'));
    await tester.pumpAndSettle();
    expect(source.removes, 1);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '已收藏'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<CollectionStatusMenu>(find.byType(CollectionStatusMenu))
          .enabled,
      isFalse,
    );
    source.removalGate!.complete();
    await tester.pumpAndSettle();
    expect(source.removes, 1);
    expect(find.widgetWithText(FilledButton, '收藏'), findsOneWidget);
    expect(find.text('已取消收藏'), findsOneWidget);
  });

  testWidgets('320宽双倍字号的长标题完整展开，底部操作仍可用', (tester) async {
    await pumpDetail(tester, _Collections(), width: 320, textScale: 2);
    final title = tester.widget<Text>(
      find.byKey(const ValueKey('detail-hero-title')),
    );
    expect(title.maxLines, isNull);
    expect(title.overflow, isNot(TextOverflow.ellipsis));
    expect(
      find.widgetWithText(FilledButton, '已收藏').hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('取消收藏'));
    await tester.pumpAndSettle();
    expect(find.text('取消收藏？'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未登录仍有底部收藏入口，不发送收藏状态请求', (tester) async {
    final source = _Collections();
    await pumpDetail(tester, source, signedIn: false);
    expect(find.text('登录后收藏').hitTestable(), findsOneWidget);
    expect(source.stateRequests, 0);
    expect(find.byKey(const ValueKey('detail-mobile-actions')), findsOneWidget);
  });

  testWidgets('桌面保持正文收藏操作，不出现手机底部栏', (tester) async {
    final source = _Collections();
    await pumpDetail(tester, source, desktop: true, width: 1200);
    expect(find.byKey(const ValueKey('detail-mobile-actions')), findsNothing);
    await tester.tap(find.byTooltip('取消收藏'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(source.removes, 1);
  });
}
