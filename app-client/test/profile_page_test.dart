import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:otaku_app/core/platform_info.dart';
import 'package:otaku_app/core/router/route_paths.dart';
import 'package:otaku_app/core/storage/memory_recent_views_store.dart';
import 'package:otaku_app/core/storage/recent_views_provider.dart';
import 'package:otaku_app/core/theme/app_theme.dart';
import 'package:otaku_app/data/datasources/collection_mock_data_source.dart';
import 'package:otaku_app/data/repositories/collection_repository.dart';
import 'package:otaku_app/features/auth/auth_controller.dart';
import 'package:otaku_app/features/profile/profile_data_source.dart';
import 'package:otaku_app/features/profile/profile_page.dart';
import 'package:otaku_app/features/profile/user_profile.dart';
import 'package:otaku_app/shared/widgets/account_menu.dart';
import 'package:otaku_app/shared/widgets/user_avatar.dart';

import 'support/test_overrides.dart';

/// 「我的」从底部弹层改成独立页（`/me`，版式对齐站点个人空间）。
///
/// 断言只钉三件用户看得见的事：**点得进去**、**数字对得上**、
/// **退出登录仍然有二次确认**。像素级版式不在这里钉——那是人眼看的活。
void main() {
  Future<ProviderContainer> pumpProfile(
    WidgetTester tester, {
    String? token,
    double scale = 1,
    Size size = const Size(390, 844),
    bool desktop = false,
    ProfileDataSource? profileSource,
  }) async {
    PlatformInfo.desktopOverride = desktop;
    addTearDown(PlatformInfo.resetOverride);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [
        ...authOverrides(token: token),
        // 历史走内存实现：真实实现要 Hive，测试里没有。
        recentViewsStoreProvider.overrideWithValue(InMemoryRecentViewsStore()),
        // 收藏的 mock 默认带 300ms 延迟，会把 pumpAndSettle 拖成「一直加载」。
        collectionDataSourceProvider.overrideWithValue(
          CollectionMockDataSource(delay: Duration.zero),
        ),
        // 不传就用默认 mock（空资料）；要验「资料里的昵称/头像」时注入桩。
        if (profileSource != null)
          profileDataSourceProvider.overrideWithValue(profileSource),
      ],
    );
    addTearDown(container.dispose);

    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            appBar: AppBar(
              title: const Text('内容页'),
              actions: const [AccountMenuButton()],
            ),
            body: const Text('原页面'),
          ),
        ),
        GoRoute(
          path: RoutePaths.profile,
          builder: (_, _) => const ProfilePage(),
        ),
        for (final (path, name) in [
          (RoutePaths.settings, '设置目的页'),
          (RoutePaths.recentHistory, '历史目的页'),
          (RoutePaths.login, '登录目的页'),
          (RoutePaths.collections, '收藏目的页'),
        ])
          GoRoute(
            path: path,
            builder: (_, _) => Scaffold(appBar: AppBar(title: Text(name))),
          ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('未登录也能进个人空间，数字留空而不是写 0', (tester) async {
    await pumpProfile(tester);
    await tester.tap(find.byTooltip('我的'));
    await tester.pumpAndSettle();

    expect(find.text('个人空间'), findsOneWidget);
    // 昵称位置与徽章此时都是「未登录」。
    expect(find.text('未登录'), findsNWidgets(2));
    // 收藏 / 看过 / 想看拿不到 -> 「—」；浏览记录是本地的，照常是 0。
    expect(find.text('—'), findsNWidgets(3));
    expect(find.widgetWithText(FilledButton, '登录'), findsOneWidget);

    // 未登录也能进设置：与改版前一致。
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('设置目的页'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    // 退回一层是个人空间，再退一层才回到内容页。
    expect(find.text('个人空间'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('原页面'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('已登录显示账号与统计数字', (tester) async {
    await pumpProfile(tester, token: signedInToken);
    await tester.tap(find.byTooltip('我的'));
    await tester.pumpAndSettle();

    expect(find.text('alice'), findsOneWidget);
    expect(find.text('已登录'), findsOneWidget);
    // Mock 收藏 5 条：看到 1 条、想看 2 条，另有 2 条未标注/在看。
    expect(find.text('5'), findsNWidgets(2)); // 统计带 + 作品收藏行
    expect(find.text('2'), findsOneWidget); // 想看
    expect(find.text('1'), findsOneWidget); // 看过
    expect(find.text('—'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('身份卡显示资料里保存的昵称，而不是登录名', (tester) async {
    await pumpProfile(
      tester,
      token: signedInToken,
      profileSource: _StubProfileDataSource(
        const UserProfile(displayName: '深夜考据派'),
      ),
    );
    await tester.tap(find.byTooltip('我的'));
    await tester.pumpAndSettle();

    // 编辑页把昵称写进 UserProfile，身份卡必须读**同一份**；
    // 只读 AuthState.user 就会出现「提示保存成功、回来名字没变」。
    expect(find.text('深夜考据派'), findsOneWidget);
    expect(find.text('alice'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('昵称是空串/全空格时回落登录名', (tester) async {
    await pumpProfile(
      tester,
      token: signedInToken,
      profileSource: _StubProfileDataSource(
        const UserProfile(displayName: '   '),
      ),
    );
    await tester.tap(find.byTooltip('我的'));
    await tester.pumpAndSettle();

    // 全空格等于没设：不能显示一片空白。
    expect(find.text('alice'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('头像接上资料的 avatarUrl', (tester) async {
    await pumpProfile(
      tester,
      token: signedInToken,
      profileSource: _StubProfileDataSource(
        const UserProfile(avatarUrl: 'https://example.com/a.png'),
      ),
    );
    await tester.tap(find.byTooltip('我的'));
    await tester.pumpAndSettle();

    // 上传接口还没落地，这个字段现在恒为 null；但接缝必须通着，
    // 否则将来「能上传了、卡片却不显示」还得再查一遍。
    final avatar = tester.widget<UserAvatar>(find.byType(UserAvatar));
    expect(avatar.avatarUrl, 'https://example.com/a.png');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('桌面账号菜单显示的也是资料里的昵称', (tester) async {
    await pumpProfile(
      tester,
      token: signedInToken,
      size: const Size(2560, 1440),
      desktop: true,
      profileSource: _StubProfileDataSource(
        const UserProfile(displayName: '深夜考据派'),
      ),
    );

    // 不用进个人空间：菜单挂在内容页 AppBar 上，它自己就会读这份资料。
    await tester.tap(find.byTooltip('账号'));
    await tester.pumpAndSettle();

    // 两处（身份卡 / 菜单）读的是同一个 provider；只改一处，
    // 就会剩下「菜单里还是旧名字」这种更难发现的 bug。
    expect(find.text('深夜考据派'), findsOneWidget);
    expect(find.text('alice'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('分区入口能进收藏与历史', (tester) async {
    await pumpProfile(tester, token: signedInToken);
    await tester.tap(find.byTooltip('我的'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('作品收藏'));
    await tester.pumpAndSettle();
    expect(find.text('收藏目的页'), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('浏览记录'));
    await tester.pumpAndSettle();
    expect(find.text('历史目的页'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('资讯收藏与作品申请标未开放且点不动', (tester) async {
    await pumpProfile(tester, token: signedInToken);
    await tester.tap(find.byTooltip('我的'));
    await tester.pumpAndSettle();

    expect(find.text('未开放'), findsNWidgets(2));
    await tester.tap(find.text('资讯收藏'));
    await tester.pumpAndSettle();
    // 仍停在本页：没有跳转就不会有目的页标题。
    expect(find.text('收藏目的页'), findsNothing);
    expect(find.text('个人空间'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('退出登录需要确认，取消不会结束会话', (tester) async {
    final container = await pumpProfile(tester, token: signedInToken);
    await tester.tap(find.byTooltip('我的'));
    await tester.pumpAndSettle();

    // 分区卡多了「登录设备」一行后，页脚不再落在首屏内；ListView 是懒构建的，
    // 得先滚过去才能拿到 element（同下面 320 宽那个用例）。
    await tester.scrollUntilVisible(find.text('退出登录'), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(container.read(authControllerProvider).isSignedIn, isTrue);

    await tester.scrollUntilVisible(find.text('退出登录'), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '退出登录'));
    await tester.pumpAndSettle();
    expect(container.read(authControllerProvider).isSignedIn, isFalse);
    expect(find.text('未登录'), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('320 宽双倍字号不溢出，仍能滚到退出登录', (tester) async {
    await pumpProfile(
      tester,
      token: signedInToken,
      size: const Size(320, 844),
      scale: 2,
    );
    await tester.tap(find.byTooltip('我的'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // ListView 是懒构建的：双倍字号下「退出登录」还在屏幕外，得先滚过去。
    await tester.scrollUntilVisible(find.text('退出登录'), 200);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('桌面 2560 宽也套侧栏，不是一张裸页面', (tester) async {
    await pumpProfile(
      tester,
      token: signedInToken,
      size: const Size(2560, 1440),
      desktop: true,
    );
    // 桌面端点的是右上角账号菜单，不是「我的」按钮，所以直接走路由。
    GoRouter.of(tester.element(find.text('内容页'))).push(RoutePaths.profile);
    await tester.pumpAndSettle();

    expect(find.text('个人空间'), findsOneWidget);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('作品收藏'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}

/// 资料桩：`fetch` 恒返回给定资料。本文件不测保存，`update` 原样返回。
class _StubProfileDataSource implements ProfileDataSource {
  _StubProfileDataSource(this.profile);

  final UserProfile profile;

  @override
  Future<UserProfile> fetch() async => profile;

  @override
  Future<UserProfile> update({
    required String? displayName,
    required String? bio,
  }) async => profile;
}
