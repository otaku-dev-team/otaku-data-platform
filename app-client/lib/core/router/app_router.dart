import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/article/article_detail_page.dart';
import '../../features/article/article_list_page.dart';
import '../../features/auth/login_page.dart';
import '../../features/collection/collection_page.dart';
import '../../features/contents/contents_page.dart';
import '../../features/detail/work_detail_page.dart';
import '../../features/home/home_page.dart';
import '../../features/schedule/schedule_page.dart';
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
/// 起始路由。
///
/// 抽成 provider 而不是写死进 [GoRouter]：测试要能指定落点——
/// 测列表页时不该先跑一遍首页的三次请求。生产默认是首页。
final appInitialLocationProvider = Provider<String>((ref) => RoutePaths.home);

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: ref.watch(appInitialLocationProvider),
    routes: [
      GoRoute(
        path: RoutePaths.home,
        builder: (context, state) => const HomePage(),
      ),
      GoRoute(
        path: RoutePaths.contents,
        builder: (context, state) => const ContentsPage(),
        routes: [
          GoRoute(
            path: RoutePaths.workDetailSegment,
            builder: (context, state) => WorkDetailPage(
              workId: state.pathParameters['workId'] ?? '',
            ),
          ),
        ],
      ),
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
      GoRoute(
        path: RoutePaths.login,
        builder: (context, state) => const LoginPage(),
      ),
      GoRoute(
        path: RoutePaths.collections,
        builder: (context, state) => const CollectionPage(),
      ),
      GoRoute(
        path: RoutePaths.schedule,
        builder: (context, state) => const SchedulePage(),
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
