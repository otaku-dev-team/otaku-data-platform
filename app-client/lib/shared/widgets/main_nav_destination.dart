import 'package:flutter/material.dart';

import '../../core/router/route_paths.dart';

/// 主导航的五个目的地。桌面侧栏与手机底栏共用这一份。
///
/// 抽出来是为了让两端**顺序与含义**不会漂移：以前侧栏那五项的序号、
/// 跳转路径、图标各写各的（`selectedIndex` / `onDestinationSelected` /
/// `destinations` 三处），改一处忘另一处就会「点 A 跳 B」。
///
/// 两种形态下的**显示文字不同**，是刻意的：
/// - 桌面侧栏 [NavigationRail] 用 `labelType: none`，只出图标 + tooltip；
/// - 手机底栏 [NavigationBar] 默认只有选中项显示文字标签。
///
/// 两边都用简称（浏览 / 资讯 / 收藏 / 新番）而不是 AppBar 的全称
/// （作品库 / 最新资讯 / 我的收藏 / 每日新番），避免底栏文字和 AppBar 标题
/// 在同一屏里重名——重名会让 `find.text('作品库')` 一次命中两个。
enum MainNavDestination {
  home(
    label: '首页',
    tooltip: '首页',
    path: RoutePaths.home,
    icon: Icons.home_outlined,
    selectedIcon: Icons.home_rounded,
  ),
  contents(
    label: '浏览',
    tooltip: '作品库',
    path: RoutePaths.contents,
    icon: Icons.grid_view_outlined,
    selectedIcon: Icons.grid_view_rounded,
  ),
  articles(
    label: '资讯',
    tooltip: '最新资讯',
    path: RoutePaths.articles,
    icon: Icons.newspaper_outlined,
    selectedIcon: Icons.newspaper_rounded,
  ),
  collections(
    label: '收藏',
    tooltip: '我的收藏',
    path: RoutePaths.collections,
    icon: Icons.bookmark_border_rounded,
    selectedIcon: Icons.bookmark_rounded,
  ),
  schedule(
    label: '新番',
    tooltip: '每日新番',
    path: RoutePaths.schedule,
    icon: Icons.calendar_today_outlined,
    selectedIcon: Icons.calendar_today_rounded,
  );

  const MainNavDestination({
    required this.label,
    required this.tooltip,
    required this.path,
    required this.icon,
    required this.selectedIcon,
  });

  /// 底栏上的文字标签（简称）。
  final String label;

  /// 图标上的无障碍 / 悬停提示（全称）。
  final String tooltip;

  /// 路由路径。
  final String path;

  final IconData icon;
  final IconData selectedIcon;

  /// 当前路由落在哪一项上；不在主导航里则返回 null。
  ///
  /// 首页必须**精确相等**判定：它的路径是 `/`，用 startsWith 会把所有路由
  /// 都算成首页（`/works`.startsWith('/') 为真）。
  static MainNavDestination? fromLocation(String location) {
    for (final d in MainNavDestination.values) {
      final hit = d == MainNavDestination.home
          ? location == RoutePaths.home
          : location.startsWith(d.path);
      if (hit) return d;
    }
    return null;
  }
}
