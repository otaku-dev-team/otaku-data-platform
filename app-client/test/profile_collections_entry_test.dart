import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:otaku_app/app.dart';
import 'package:otaku_app/core/platform_info.dart';
import 'package:otaku_app/core/router/app_router.dart';
import 'package:otaku_app/core/router/route_paths.dart';
import 'package:otaku_app/core/storage/memory_recent_views_store.dart';
import 'package:otaku_app/core/storage/recent_views_provider.dart';
import 'package:otaku_app/features/article_favorite/article_favorite_list.dart';

import 'support/test_overrides.dart';

/// 个人空间 → 收藏页的两个入口（`_SectionCard`）。
///
/// ⚠️ 这份测试**必须用真实 `OtakuApp` 路由**。`profile_page_test.dart` 里的
/// 收藏目的页是平铺 GoRoute，覆盖不到 `/collections` 是
/// `StatefulShellRoute` branch 这件事：那里 `push` 也能过，真机上却会推出
/// 一份重复的 shell —— 收藏页 `canPop=false`，AppBar 没有返回箭头（实测
/// `BackButton=0`），底栏却高亮「收藏」，看起来就像「打不开」。
/// 所以入口用 `go`，这里钉住「真能进、分段对、底栏选中收藏」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpProfile(WidgetTester tester) async {
    PlatformInfo.desktopOverride = false;
    addTearDown(PlatformInfo.resetOverride);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [
        ...authOverrides(token: signedInToken),
        recentViewsStoreProvider.overrideWithValue(InMemoryRecentViewsStore()),
        appInitialLocationProvider.overrideWithValue(RoutePaths.profile),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const OtakuApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('个人空间'), findsOneWidget);
  }

  testWidgets('点「资讯收藏」：进收藏页且落在资讯分段，底栏选中收藏', (tester) async {
    await pumpProfile(tester);

    await tester.ensureVisible(find.text('资讯收藏'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('资讯收藏'));
    await tester.pumpAndSettle();

    expect(find.text('我的收藏'), findsOneWidget);
    // 分段真的切了，不是停在「作品」。
    expect(find.byType(ArticleFavoriteList), findsOneWidget);
    // 底栏把收藏标成当前 tab（不是停在「我的」或首页）。
    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.selectedIndex, 3, reason: '收藏是第 4 个主导航项');
    expect(tester.takeException(), isNull);
  });

  testWidgets('点「作品收藏」：进收藏页，不渲染资讯分段', (tester) async {
    await pumpProfile(tester);

    await tester.tap(find.text('作品收藏'));
    await tester.pumpAndSettle();

    expect(find.text('我的收藏'), findsOneWidget);
    expect(find.byType(ArticleFavoriteList), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
