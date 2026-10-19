import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/contents/contents_page.dart';
import '../../features/detail/work_detail_page.dart';
import '../../shared/widgets/empty_state.dart';
import 'route_paths.dart';

/// 第一阶段只有两条路由：列表与详情。详情是列表的子路由，
/// 这样返回时列表的滚动位置和已加载的分页都还在。
final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: RoutePaths.contents,
    routes: [
      GoRoute(
        path: '/',
        redirect: (context, state) => RoutePaths.contents,
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
