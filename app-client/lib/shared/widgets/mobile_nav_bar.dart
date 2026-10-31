import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/platform_info.dart';
import '../../core/theme/app_theme.dart';
import 'glass_backdrop.dart';
import 'main_nav_destination.dart';

/// 手机端主导航：底部一条 [NavigationBar]。
///
/// 与 [DesktopNavShell] 是同一件事的两端形态（`docs/flutter-lead-plan.md` §6
/// 「两端差异清单」第一行：主导航 手机 `NavigationBar` / 桌面 `NavigationRail`）。
///
/// 三条边界：
/// 1. **按平台判断，不只看宽度**。手机横屏也能超过 600 逻辑像素，
///    但 §6 里这是平台差异，不是纯响应式差异，所以先判平台。
/// 2. **只包「主导航可达」的页面**。详情页是列表的子路由，不挂这层——
///    手机上详情整页 push，底下再挂一条底栏会把正文压掉一大截。
/// 3. **五项与侧栏同序**：首页 / 作品库 / 资讯 / 收藏 / 新番。
///    两端共用 [MainNavDestination]，改一处不会只改一头。
///
/// **为什么是 `Scaffold.bottomNavigationBar` 而不是自己再套一层 Scaffold**：
/// 页面自己的 `Scaffold` 在里面，外壳再套一个就成了「Scaffold 套 Scaffold」——
/// 内层的 `SnackBar`、`ScaffoldMessenger` 与 `backgroundColor` 填充都会各走各的，
/// 底栏还会把内层内容顶上去之后再多算一次安全区。
/// 所以这里只提供底栏 widget，由页面自己挂到 `Scaffold.bottomNavigationBar`。
class MobileNavBar extends StatelessWidget {
  const MobileNavBar({super.key});

  /// 页面把它挂到 `Scaffold.bottomNavigationBar` 上。
  ///
  /// 桌面端返回 [SizedBox.shrink]：桌面有侧栏，底部再挂一条就是两套主导航。
  static Widget forScaffold(BuildContext context) {
    if (PlatformInfo.isDesktop) return const SizedBox.shrink();
    return const MobileNavBar();
  }

  @override
  Widget build(BuildContext context) {
    final router = GoRouter.maybeOf(context);
    final location =
        router?.routerDelegate.currentConfiguration.uri.path ?? '';
    final current = MainNavDestination.fromLocation(location);

    // `NavigationBar` 的 `selectedIndex` 被断言死在 `0 <= i < destinations.length`，
    // 没有「一个都不选中」的状态。匹配不到主导航项时（设置页、详情页），
    // 硬传 -1 会直接抛断言，传 0 又会谎报「当前在首页」。
    // 所以这里不猜——**不挂底栏**。这几页本来也不该有底栏：
    // 设置是应用配置、详情是列表的子页，都不属于「在内容之间跳」这一层。
    if (current == null) return const SizedBox.shrink();

    final bar = NavigationBar(
      // 玻璃模式下底栏自己透明（主题里已设），模糊由外层 [GlassSurface] 提供。
      backgroundColor: AppTheme.isGlass(context)
          ? Colors.transparent
          : null,
      selectedIndex: MainNavDestination.values.indexOf(current),
      onDestinationSelected: (index) {
        // 走 goBranch 而不是 go(path)：切 tab 只换显隐，页面不被销毁，
        // 作品库翻到第几页、滚到哪里都还在。`go(path)` 会整棵替换，
        // 切回来等于重开。
        final shell = StatefulNavigationShell.maybeOf(context);
        if (shell != null) {
          shell.goBranch(index);
          return;
        }
        // 不在 shell 里（页面被单独 pump 的测试、或以后挪出主壳）时退回 go。
        GoRouter.maybeOf(context)?.go(MainNavDestination.values[index].path);
      },
      destinations: [
        for (final d in MainNavDestination.values)
          NavigationDestination(
            icon: Tooltip(message: d.tooltip, child: _NavIcon(d.icon)),
            selectedIcon: Tooltip(
              message: d.tooltip,
              child: _NavIcon(d.selectedIcon),
            ),
            label: d.label,
          ),
      ],
    );

    // 玻璃模式：底栏是常驻的那一层，值得真做一次模糊（列表滚动时下面的
    // 卡片会从它后面透过去）。卡片不做——几十个 BackdropFilter 会把帧时间吃掉。
    if (!AppTheme.isGlass(context)) return bar;
    return GlassSurface(child: bar);
  }
}

/// 底栏图标：出现时轻轻放大一下。
///
/// [NavigationBar] 只在选中时把 `icon` 换成 `selectedIcon`——**瞬时替换，没有过渡**，
/// 切 tab 时图标是「啪」地换掉的。
///
/// 这里套一层 `TweenAnimationBuilder`：每次这个图标被挂到树上就播一次
/// 0.92 → 1.0（180ms）。切换 tab 时 NavigationBar 会重建 icon widget，
/// 所以动画只在切换那一刻跑，不会常驻抖动。
///
/// 幅度刻意压得很小、曲线用 `easeOutCubic`（不带过冲）：五个图标在首屏
/// 一起入场时，幅度大的过冲会显得满屏都在跳。想要更明显的形变（Mihon 那种
/// 图标本身变形状）需要给每个目的地做一套矢量动画，那是另一个量级的事。
class _NavIcon extends StatelessWidget {
  const _NavIcon(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.92, end: 1),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      // Transform.scale 不参与布局（只改绘制），图标占位始终是 24×24，
      // 不会因为动画把相邻的 label 挤动。
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
      child: Icon(icon),
    );
  }
}
