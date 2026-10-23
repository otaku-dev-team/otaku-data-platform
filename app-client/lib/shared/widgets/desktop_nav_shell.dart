import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/platform_info.dart';
import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';

/// 桌面端外壳：窗口够宽时在左侧常驻一条 [NavigationRail]。
///
/// 只做容器，页面的 `Scaffold` 原封不动留在内层——AppBar、SnackBar 都归页面自己管，
/// 侧栏不碰业务状态。
///
/// 三条边界：
/// 1. **按平台判断，不只看宽度**。手机横屏也能超过 600，但 §6 里这是平台差异，
///    不是纯响应式差异，所以先判平台再判宽度。
/// 2. **图标 + tooltip，不显示文字标签**。列表页 AppBar 的标题也叫「作品库」，
///    侧栏再写一遍会让同一屏出现两个同名文本，`find.text('作品库')` 会一次命中两个。
/// 3. **详情页不在这个外壳里**。它是列表的子路由，桌面端详情本身已经是左右双栏，
///    再挤一条侧栏会把正文压到 720 以下，双栏直接退回堆叠。
class DesktopNavShell extends StatelessWidget {
  const DesktopNavShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!PlatformInfo.isDesktop) return child;

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < AppLayout.railBreakpoint) return child;
        return Scaffold(
          body: Row(
            children: [
              _buildRail(context),
              const VerticalDivider(width: 1, thickness: 1),
              Expanded(child: child),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRail(BuildContext context) {
    final location = _locationOf(context);
    final onCollections = location.startsWith(RoutePaths.collections);
    final onSchedule = location.startsWith(RoutePaths.schedule);
    final onArticles = location.startsWith(RoutePaths.articles);
    final onContents = location.startsWith(RoutePaths.contents);

    return NavigationRail(
      // 路由不认识时（比如测试里单独 pump 某页）四项都不选中，
      // 而不是默认高亮第一项——高亮错了比不亮更误导。
      // 顺序与下面的 destinations 一致：作品库 / 资讯 / 收藏 / 新番。
      selectedIndex: onContents
          ? 0
          : onArticles
          ? 1
          : onCollections
          ? 2
          : onSchedule
          ? 3
          : null,
      labelType: NavigationRailLabelType.none,
      groupAlignment: -0.85,
      onDestinationSelected: (index) {
        final router = GoRouter.maybeOf(context);
        if (router == null) return;
        router.go(switch (index) {
          0 => RoutePaths.contents,
          1 => RoutePaths.articles,
          2 => RoutePaths.collections,
          _ => RoutePaths.schedule,
        });
      },
      destinations: const [
        NavigationRailDestination(
          icon: Tooltip(message: '作品库', child: Icon(Icons.grid_view_outlined)),
          selectedIcon: Tooltip(
            message: '作品库',
            child: Icon(Icons.grid_view_rounded),
          ),
          label: Text('浏览'),
        ),
        NavigationRailDestination(
          icon: Tooltip(
            message: '最新资讯',
            child: Icon(Icons.newspaper_outlined),
          ),
          selectedIcon: Tooltip(
            message: '最新资讯',
            child: Icon(Icons.newspaper_rounded),
          ),
          label: Text('资讯'),
        ),
        NavigationRailDestination(
          icon: Tooltip(
            message: '我的收藏',
            child: Icon(Icons.bookmark_border_rounded),
          ),
          selectedIcon: Tooltip(
            message: '我的收藏',
            child: Icon(Icons.bookmark_rounded),
          ),
          label: Text('收藏'),
        ),
        NavigationRailDestination(
          icon: Tooltip(
            message: '每日新番',
            child: Icon(Icons.calendar_today_outlined),
          ),
          selectedIcon: Tooltip(
            message: '每日新番',
            child: Icon(Icons.calendar_today_rounded),
          ),
          label: Text('新番'),
        ),
      ],
    );
  }

  static String _locationOf(BuildContext context) {
    final router = GoRouter.maybeOf(context);
    if (router == null) return '';
    return router.routerDelegate.currentConfiguration.uri.path;
  }
}
