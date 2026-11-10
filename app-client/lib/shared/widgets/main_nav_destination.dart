import 'package:flutter/material.dart';

import '../../core/router/route_paths.dart';

/// 手机底栏上的一项与桌面侧栏不同时，用它描述手机形态。
///
/// 存在的理由只有一个：**两端导航的语义可以不同，但顺序与「谁在哪一位」不能漂**。
/// 目前只有第 5 位不同——桌面是「每日新番」（切 tab），手机是「我的」
/// （push 出独立页，带返回、无底栏）。其余项两端一致，保持 `null`。
@immutable
class MobileNavVariant {
  const MobileNavVariant({
    required this.label,
    required this.tooltip,
    required this.path,
    required this.icon,
    required this.selectedIcon,
    this.pushes = false,
  });

  /// 底栏上的文字标签（简称）。
  final String label;

  /// 图标上的无障碍 / 悬停提示（全称）。
  final String tooltip;

  /// 点击后到达的路径。
  final String path;

  final IconData icon;
  final IconData selectedIcon;

  /// true：点它不是切 tab，而是 push 一个独立页。
  ///
  /// 这类项**永远不高亮、不进 shell**——它不参与 `selectedIndex`，
  /// 因为这个页面本身就没有底栏。
  final bool pushes;
}

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
    // 手机第 5 位是「我的」：一个 push 出来的独立页，不是 tab。
    // 桌面仍是「每日新番」，桌面侧栏的 destinations 是手写的，不受影响。
    mobile: MobileNavVariant(
      label: '我的',
      tooltip: '我的',
      path: RoutePaths.profile,
      icon: Icons.person_outline_rounded,
      selectedIcon: Icons.person_rounded,
      pushes: true,
    ),
  );

  const MainNavDestination({
    required this.label,
    required this.tooltip,
    required this.path,
    required this.icon,
    required this.selectedIcon,
    this.mobile,
  });

  /// 底栏上的文字标签（简称）。
  final String label;

  /// 图标上的无障碍 / 悬停提示（全称）。
  final String tooltip;

  /// 路由路径。
  final String path;

  final IconData icon;
  final IconData selectedIcon;

  /// 手机形态的覆盖值；为 null 表示两端一致。
  final MobileNavVariant? mobile;

  // —— 手机形态的取值，没有覆盖时回落到基础值 ——

  String get mobileLabel => mobile?.label ?? label;
  String get mobileTooltip => mobile?.tooltip ?? tooltip;
  String get mobilePath => mobile?.path ?? path;
  IconData get mobileIcon => mobile?.icon ?? icon;
  IconData get mobileSelectedIcon => mobile?.selectedIcon ?? selectedIcon;
  bool get mobilePushes => mobile?.pushes ?? false;

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

  /// 手机底栏用：只匹配**真正会切成 tab** 的项。
  ///
  /// 与 [fromLocation] 的差别有两处：
  /// 1. 跳过 `mobilePushes` 的项。第 5 位在手机上是 push 出去的「我的」，
  ///    不该被当成当前 tab——一旦匹配上，底栏会挂出来、并且把「我的」
  ///    高亮在每日新番的内容上。
  /// 2. 匹配的是手机路径（`mobilePath`），不是桌面路径。
  static MainNavDestination? fromMobileLocation(String location) {
    for (final d in MainNavDestination.values) {
      if (d.mobilePushes) continue;
      final path = d.mobilePath;
      final hit = d == MainNavDestination.home
          ? location == RoutePaths.home
          : location.startsWith(path);
      if (hit) return d;
    }
    return null;
  }
}
