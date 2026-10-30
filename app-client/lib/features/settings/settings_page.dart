import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_config.dart';
import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';
import '../../shared/widgets/desktop_nav_shell.dart';
import 'settings_controller.dart';
import 'settings_widgets.dart';
import 'storage_settings_page.dart';

/// 设置主页：只放分组入口，内容在二级页。
///
/// **为什么单独一页而不是塞进账号菜单**：主题与缓存是设备级的东西，
/// 未登录的用户同样需要；账号菜单在未登录时根本不存在（只有「登录」按钮），
/// 塞进去等于把设置藏起来。
///
/// **为什么拆二级**：以前三块内容（主题 / 缓存 / 关于）平铺在一屏，
/// 现在还能看；但每加一项就往下长一截，最后会变成一条要滚很久的走廊。
/// 主页面固定三行，加东西只影响它自己那页。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final usage = ref.watch(cacheUsageProvider);

    return DesktopNavShell(
      child: Scaffold(
        appBar: AppBar(title: const Text('设置')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppLayout.listMaxWidth),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                AppLayout.pagePadding,
                8,
                AppLayout.pagePadding,
                24,
              ),
              children: [
                SettingsCard(
                  child: Column(
                    children: [
                      _Entry(
                        icon: Icons.palette_outlined,
                        title: '外观',
                        summary: _themeLabel(mode),
                        target: RoutePaths.appearanceSettings,
                      ),
                      const Divider(height: 1),
                      _Entry(
                        icon: Icons.cloud_off_outlined,
                        title: '离线缓存',
                        summary: describeCacheUsage(usage),
                        target: RoutePaths.storageSettings,
                      ),
                      const Divider(height: 1),
                      _Entry(
                        icon: Icons.info_outline_rounded,
                        title: '关于',
                        summary: 'v${AppConfig.version}',
                        target: RoutePaths.aboutSettings,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    '主题与缓存是设备级设置，不随账号同步。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _themeLabel(ThemeMode mode) => switch (mode) {
    ThemeMode.system => '跟随系统',
    ThemeMode.light => '浅色',
    ThemeMode.dark => '深色',
  };
}

/// 一行入口：图标 + 标题 + 当前值 + 右箭头。
///
/// 右侧写「当前值」而不是只写标题：设置页最常被问的两件事就是
/// 「现在是深色还是浅色」「缓存占了多少」，让用户点进去才知道就是白跑一趟。
class _Entry extends StatelessWidget {
  const _Entry({
    required this.icon,
    required this.title,
    required this.summary,
    required this.target,
  });

  final IconData icon;
  final String title;
  final String summary;
  final String target;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(icon, color: theme.colorScheme.onSurfaceVariant),
      title: Text(title, style: theme.textTheme.bodyLarge),
      subtitle: Text(
        summary,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Icon(
        Icons.chevron_right_rounded,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      // push 而不是 go：设置页不在主导航壳里，返回要能回到这一屏。
      onTap: () => context.push(target),
    );
  }
}
