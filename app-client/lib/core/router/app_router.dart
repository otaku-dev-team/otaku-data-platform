import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/article/article_detail_page.dart';
import '../../features/article/article_list_page.dart';
import '../../features/auth/login_page.dart';
import '../../features/auth/site_auth_webview_page.dart';
import '../../features/collection/collection_page.dart';
import '../../features/contents/contents_page.dart';
import '../../features/detail/work_detail_page.dart';
import '../../features/home/home_page.dart';
import '../../features/devices/device_page.dart';
import '../../features/my_comment/my_comment_page.dart';
import '../../features/person/person_page.dart';
import '../../features/persona/persona_page.dart';
import '../../features/persona/persona_quiz_page.dart';
import '../../features/profile/profile_edit_page.dart';
import '../../features/profile/profile_page.dart';
import '../../features/recent/recent_history_page.dart';
import '../../features/schedule/schedule_page.dart';
import '../../features/settings/about_settings_page.dart';
import '../../features/settings/appearance_settings_page.dart';
import '../../features/settings/settings_page.dart';
import '../../features/settings/storage_settings_page.dart';
import '../../shared/widgets/empty_state.dart';
import 'route_paths.dart';

/// 第一阶段只有两条路由：列表与详情。详情是列表的子路由，
/// 这样返回时列表的滚动位置和已加载的分页都还在。
///
/// 第二阶段加了登录与收藏两条平级路由：它们不是列表的子页面，
/// 从任何地方都能直接进。
///
/// 资讯同样平级：列表 `/articles`，详情是它的子路由（与作品详情同构）。
///
/// 首页 `/` 是落地页，与其余页面平级——它不是"列表的子页"，
/// 从任何地方点侧栏的「首页」都能直接回去。
///
/// ## 五个主导航页各自一条 branch
///
/// 从平铺 `GoRoute` 改成 `StatefulShellRoute.indexedStack` 的原因很具体：
/// 平铺时切 tab 是 `go(path)` 整棵替换，作品库翻到第 5 页再切去资讯、
/// 切回来就从顶部重来（数据还在 provider 里，滚动位置没了）。改用分支后
/// 每个 tab 有自己的 `Navigator`，`goBranch` 只切显隐，页面不被销毁。
///
/// **branches 的顺序必须与 [MainNavDestination] 一致**——底栏和侧栏都是
/// 用枚举下标去调 `goBranch(index)` 的，顺序一错就是「点 A 跳 B」。
/// 起始路由。
///
/// 抽成 provider 而不是写死进 [GoRouter]：测试要能指定落点——
/// 测列表页时不该先跑一遍首页的三次请求。生产默认是首页。
final appInitialLocationProvider = Provider<String>((ref) => RoutePaths.home);

/// 根 Navigator 的 key。
///
/// 远程更新的启动检查挂在 `MaterialApp` 之外（与 `SiteAuthBootstrap` 同一层），
/// 要弹对话框就得拿到 Navigator 的 context。做成 provider 而不是顶层全局：
/// 每个 `ProviderScope`（每个测试）各拿一把新 key，避免重复 GlobalKey。
final appNavigatorKeyProvider = Provider<GlobalKey<NavigatorState>>(
  (ref) => GlobalKey<NavigatorState>(debugLabel: 'root-navigator'),
);

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: ref.watch(appNavigatorKeyProvider),
    initialLocation: ref.watch(appInitialLocationProvider),
    routes: [
      StatefulShellRoute.indexedStack(
        // 外壳只做一件事：把当前分支显示出来。底栏/侧栏仍由各页面自己挂
        // （`MobileNavBar.forScaffold` / `DesktopNavShell`），因为页面本来就有
        // 自己的 `Scaffold`；这里再套一层会出现 Scaffold 套 Scaffold，
        // SnackBar 与安全区都会被算两遍。
        builder: (context, state, navigationShell) => navigationShell,
        branches: [
          // 顺序 = MainNavDestination.values。详见文件头注释。
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: RoutePaths.home,
                builder: (context, state) => const HomePage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: RoutePaths.contents,
                builder: (context, state) => ContentsPage(
                  focusSearch: state.uri.queryParameters['search'] == '1',
                ),
                routes: [
                  GoRoute(
                    path: RoutePaths.workDetailSegment,
                    builder: (context, state) => WorkDetailPage(
                      workId: state.pathParameters['workId'] ?? '',
                      // 只从列表点进来时才有：详情页拿它接一次封面转场。
                      heroTag: state.uri.queryParameters['hero'],
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: RoutePaths.articles,
                builder: (context, state) => const ArticleListPage(),
                routes: [
                  GoRoute(
                    path: RoutePaths.articleDetailSegment,
                    builder: (context, state) => ArticleDetailPage(
                      articleId: state.pathParameters['articleId'] ?? '',
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: RoutePaths.collections,
                builder: (context, state) => const CollectionPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: RoutePaths.schedule,
                builder: (context, state) => const SchedulePage(),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: RoutePaths.login,
        builder: (context, state) => const LoginPage(),
      ),
      GoRoute(
        path: RoutePaths.siteAuth,
        builder: (context, state) {
          final args = state.extra;
          if (args is! SiteAuthWebViewArgs) {
            // 只有 launcher 会带 extra 打开这里；直接输入路径说明调用方式错了。
            return Scaffold(
              appBar: AppBar(),
              body: const EmptyState(
                icon: Icons.link_off_rounded,
                title: '这个页面不能直接打开',
                message: '请从登录页进入。',
              ),
            );
          }
          return SiteAuthWebViewPage(args: args);
        },
      ),
      GoRoute(
        path: RoutePaths.recentHistory,
        builder: (context, state) => const RecentHistoryPage(),
      ),
      // #455 人物详情：从作品详情的 staff / 声优行点进来。挂在根级而不是某个
      // tab 分支下——它可能从作品页、人物页自身或未来的搜索进来，不属于某个 tab。
      GoRoute(
        path: '${RoutePaths.persons}/${RoutePaths.personSegment}',
        builder: (context, state) =>
            PersonPage(personId: state.pathParameters['personId'] ?? ''),
      ),
      GoRoute(
        path: RoutePaths.profile,
        builder: (context, state) => const ProfilePage(),
        routes: [
          // #375 阿宅画像：个人空间的二级页，从 /me 点进来、返回也回 /me。
          GoRoute(
            path: RoutePaths.personaSegment,
            builder: (context, state) => const PersonaPage(),
            routes: [
              // #505 冷启动补标：一部一部点「看过 / 在看 / 抛弃」，
              // 答案写进 collection，标完回画像页。
              GoRoute(
                path: RoutePaths.personaQuizSegment,
                builder: (context, state) => const PersonaQuizPage(),
              ),
            ],
          ),
          // #378 登录设备：同上，账号数据的二级视图。
          GoRoute(
            path: RoutePaths.devicesSegment,
            builder: (context, state) => const DevicePage(),
          ),
          // #378 第一层：昵称 / 简介编辑 + 首字色块头像兜底。
          GoRoute(
            path: RoutePaths.profileEditSegment,
            builder: (context, state) => const ProfileEditPage(),
          ),
          // #449 我的评论：注册但不从任何入口 push——本轮「功能存在但不启用」。
          GoRoute(
            path: RoutePaths.myCommentSegment,
            builder: (context, state) => const MyCommentPage(),
          ),
        ],
      ),
      GoRoute(
        path: RoutePaths.settings,
        builder: (context, state) => const SettingsPage(),
        routes: [
          GoRoute(
            path: RoutePaths.appearanceSettingsSegment,
            builder: (context, state) => const AppearanceSettingsPage(),
          ),
          GoRoute(
            path: RoutePaths.storageSettingsSegment,
            builder: (context, state) => const StorageSettingsPage(),
          ),
          GoRoute(
            path: RoutePaths.aboutSettingsSegment,
            builder: (context, state) => const AboutSettingsPage(),
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      appBar: AppBar(),
      body: EmptyState(
        icon: Icons.link_off_rounded,
        title: '页面不存在',
        message: state.error?.toString(),
        action: FilledButton.tonal(
          onPressed: () => context.go(RoutePaths.contents),
          child: const Text('回到列表'),
        ),
      ),
    ),
  );
});
