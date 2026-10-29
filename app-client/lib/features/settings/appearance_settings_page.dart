import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'settings_controller.dart';
import 'settings_widgets.dart';

/// 外观：主题模式。
class AppearanceSettingsPage extends ConsumerWidget {
  const AppearanceSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const SettingsSubPage(
      title: '外观',
      // 只有一张卡，卡里已经有「主题」标题了，再加一个小节标题就是同一个词
      // 在同一屏出现两次。
      children: [_ThemeModeCard(), SizedBox(height: 12), _ExperimentCard()],
    );
  }
}

class _ThemeModeCard extends ConsumerWidget {
  const _ThemeModeCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final mode = ref.watch(themeModeProvider);

    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('主题', style: theme.textTheme.bodyLarge),
          const SizedBox(height: 2),
          Text(
            '「跟随系统」会随操作系统的深浅色切换。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          // 三段的宽度在窄屏（320dp）上会顶到边，用 FittedBox 等比缩一点，
          // 而不是让它在小屏上直接溢出报黄条。
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: SegmentedButton<ThemeMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('跟随系统')),
                ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
                ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
              ],
              selected: {mode},
              onSelectionChanged: (selection) =>
                  ref.read(themeModeProvider.notifier).select(selection.first),
            ),
          ),
        ],
      ),
    );
  }
}

/// 两个外观实验开关：系统取色与玻璃质感。
///
/// 都默认关、随时可关——关掉就是发布版的品牌蓝 + 实心卡片。放在同一页而不是
/// 藏进开发者选项：这是要给用户自己判断的东西（有人就是喜欢壁纸色），
/// 但副标题必须写清代价（品牌色消失 / 更耗电），不能只写「好看」。
class _ExperimentCard extends ConsumerWidget {
  const _ExperimentCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appearanceProvider);

    return SettingsCard(
      child: Column(
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('跟随系统取色'),
            subtitle: const Text(
              '用壁纸配色代替品牌蓝（Android 12+）。关闭则恢复品牌色。',
            ),
            value: appearance.dynamicColor,
            onChanged: (value) => ref
                .read(appearanceProvider.notifier)
                .setDynamicColor(value),
          ),
          const Divider(height: 1),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('玻璃质感'),
            subtitle: const Text(
              '半透明与模糊的层叠效果，需要更多图形计算，低端机可能更耗电。',
            ),
            value: appearance.glass,
            onChanged: (value) =>
                ref.read(appearanceProvider.notifier).setGlass(value),
          ),
        ],
      ),
    );
  }
}
