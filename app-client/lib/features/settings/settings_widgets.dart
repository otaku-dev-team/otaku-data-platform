import 'package:flutter/material.dart';

import '../../core/theme/app_layout.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/desktop_nav_shell.dart';

/// 设置页共用的小组件。
///
/// 主页面与三个二级页都用同一张卡片、同一种小节标题，避免每页自己定一遍
/// 圆角、内边距、标题颜色——以前这些是 `settings_page.dart` 里的私有类，
/// 拆页之后要么复制三份，要么提出来。提出来。
class SettingsCard extends StatelessWidget {
  const SettingsCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: child,
      ),
    );
  }
}

/// 小节标题。与侧栏选中态同色：一眼能看出这是分节标题，而不是又一条正文。
class SettingsSectionTitle extends StatelessWidget {
  const SettingsSectionTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: AppTheme.brandInk(context),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 二级页的通用骨架：桌面侧栏外壳 + AppBar + 居中的定宽滚动内容。
///
/// 三页的差异只有标题和内容，骨架重复三遍没有意义；更重要的是
/// [DesktopNavShell] 一旦漏套，桌面宽屏上就没有侧栏——这个 bug 在默认
/// 测试视口里看不出来，只有 2560 宽的钉子测试才露。
class SettingsSubPage extends StatelessWidget {
  const SettingsSubPage({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DesktopNavShell(
      child: Scaffold(
        appBar: AppBar(title: Text(title)),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppLayout.listMaxWidth),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                AppLayout.pagePadding,
                4,
                AppLayout.pagePadding,
                24,
              ),
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}
