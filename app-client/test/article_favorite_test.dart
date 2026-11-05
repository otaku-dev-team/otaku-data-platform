import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:otaku_app/core/platform_info.dart';
import 'package:otaku_app/core/router/route_paths.dart';
import 'package:otaku_app/core/theme/app_theme.dart';
import 'package:otaku_app/data/datasources/collection_data_source.dart';
import 'package:otaku_app/data/models/article.dart';
import 'package:otaku_app/data/models/collection_entry.dart';
import 'package:otaku_app/data/models/collection_state.dart';
import 'package:otaku_app/data/repositories/collection_repository.dart';
import 'package:otaku_app/features/article/article_card.dart';
import 'package:otaku_app/features/article_favorite/article_favorite_data_source.dart';
import 'package:otaku_app/features/article_favorite/article_favorite_entry.dart';
import 'package:otaku_app/features/collection/collection_page.dart';
import 'package:otaku_app/shared/widgets/empty_state.dart';
import 'package:otaku_app/shared/widgets/error_state.dart';

import 'support/test_overrides.dart';

/// 资讯收藏的只读骨架（#377）。接口未定稿，所以这里只验「页面接得上、四态对」，
/// 不验取消收藏——那要等契约的幂等语义。
class _FakeArticleFavorites implements ArticleFavoriteDataSource {
  _FakeArticleFavorites({this.items = const [], this.fail = false});

  final List<ArticleFavoriteEntry> items;
  final bool fail;
  int calls = 0;

  @override
  Future<List<ArticleFavoriteEntry>> fetchAll({required String userId}) async {
    calls++;
    if (fail) throw StateError('boom');
    return items;
  }
}

/// 作品收藏在这一组用例里只是「旁边那个分段」，给空实现即可。
class _EmptyCollections implements CollectionDataSource {
  @override
  Future<List<CollectionEntry>> fetchAll({CollectionStatus? status}) async =>
      const [];

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

  @override
  Future<void> remove(String workId) => throw UnimplementedError();
}

void main() {
  Future<void> pumpFavorites(
    WidgetTester tester, {
    required ArticleFavoriteDataSource source,
    bool signedIn = true,
  }) async {
    PlatformInfo.desktopOverride = false;
    addTearDown(PlatformInfo.resetOverride);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final router = GoRouter(
      initialLocation: RoutePaths.collections,
      routes: [
        GoRoute(
          path: RoutePaths.collections,
          builder: (_, _) => const CollectionPage(),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...authOverrides(token: signedIn ? signedInToken : null),
          collectionDataSourceProvider.overrideWithValue(_EmptyCollections()),
          articleFavoriteDataSourceProvider.overrideWithValue(source),
        ],
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('默认停在作品段，资讯列表不提前加载', (tester) async {
    final source = _FakeArticleFavorites(
      items: [
        ArticleFavoriteEntry(
          article: const ArticleSummary(articleId: 'A-1', title: '不该提前出现的资讯'),
        ),
      ],
    );
    await pumpFavorites(tester, source: source);

    expect(find.widgetWithText(ChoiceChip, '资讯'), findsOneWidget); // 分段 chip
    expect(find.byType(ArticleCard), findsNothing);
    expect(source.calls, 0);
  });

  testWidgets('切到资讯段渲染收藏，卡片复用资讯流样式', (tester) async {
    await pumpFavorites(
      tester,
      source: _FakeArticleFavorites(
        items: [
          ArticleFavoriteEntry(
            article: const ArticleSummary(
              articleId: 'A-1',
              title: '收藏的资讯一',
              sourceName: 'Mock 新闻',
              publishedAt: '2026-11-02T10:00:00Z',
            ),
            favoritedAt: DateTime.utc(2026, 11, 3),
          ),
          ArticleFavoriteEntry(
            article: const ArticleSummary(articleId: 'A-2', title: '收藏的资讯二'),
          ),
        ],
      ),
    );

    await tester.tap(find.widgetWithText(ChoiceChip, '资讯'));
    await tester.pumpAndSettle();

    expect(find.text('收藏的资讯一'), findsOneWidget);
    expect(find.text('收藏的资讯二'), findsOneWidget);
    expect(find.byType(ArticleCard), findsNWidgets(2));
  });

  testWidgets('没有收藏时给空态，而不是一片空白', (tester) async {
    await pumpFavorites(tester, source: _FakeArticleFavorites());

    await tester.tap(find.widgetWithText(ChoiceChip, '资讯'));
    await tester.pumpAndSettle();

    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('还没有收藏的资讯'), findsOneWidget);
  });

  testWidgets('拉取失败给错误态与重试入口', (tester) async {
    await pumpFavorites(tester, source: _FakeArticleFavorites(fail: true));

    await tester.tap(find.widgetWithText(ChoiceChip, '资讯'));
    await tester.pumpAndSettle();

    expect(find.byType(ErrorState), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('资讯段点刷新会重拉资讯，而不是刷作品列表', (tester) async {
    final source = _FakeArticleFavorites(
      items: [
        ArticleFavoriteEntry(
          article: const ArticleSummary(articleId: 'A-1', title: '收藏的资讯'),
        ),
      ],
    );
    await pumpFavorites(tester, source: source);

    await tester.tap(find.widgetWithText(ChoiceChip, '资讯'));
    await tester.pumpAndSettle();
    expect(source.calls, 1);

    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(source.calls, 2);
  });

  testWidgets('未登录不显示分段，仍然是登录引导', (tester) async {
    await pumpFavorites(
      tester,
      source: _FakeArticleFavorites(),
      signedIn: false,
    );

    expect(find.text('登录后可以跨端同步收藏'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '资讯'), findsNothing);
  });
}
