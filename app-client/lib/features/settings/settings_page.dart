import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/platform_info.dart';
import '../../core/storage/work_cache.dart';
import '../../core/theme/app_layout.dart';
import '../../shared/widgets/desktop_nav_shell.dart';
import '../reminders/reminder_scheduler.dart';
import '../reminders/reminder_service.dart';
import '../reminders/reminder_settings.dart';
import 'settings_controller.dart';

/// 设置：外观 / 离线缓存 / 关于。
///
/// **为什么单独一页而不是塞进账号菜单**：主题与缓存是设备级的东西，
/// 未登录的用户同样需要；账号菜单在未登录时根本不存在（只有「登录」按钮），
/// 塞进去等于把设置藏起来。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DesktopNavShell(
      child: Scaffold(
        appBar: AppBar(title: const Text('设置')),
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
              children: const [
                _SectionTitle('外观'),
                _ThemeModeSection(),
                _SectionTitle('提醒'),
                _ReminderSection(),
                _SectionTitle('离线缓存'),
                _CacheSection(),
                _SectionTitle('关于'),
                _AboutSection(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          // 与侧栏选中态同色：一眼能看出这是分节标题，而不是又一条正文。
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 分节容器。三块用同一种卡片，避免每块自己定一遍圆角与内边距。
class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child});

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

class _ThemeModeSection extends ConsumerWidget {
  const _ThemeModeSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final mode = ref.watch(themeModeProvider);

    return _SectionCard(
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

/// 追番提醒。**默认关**，打开时才申请系统通知权限。
///
/// 桌面端整项禁用并说明原因：Windows 的本地通知要 AUMID/MSIX 打包配合，
/// 牵动部署（W6 休眠）。与其给一个点了没反应的开关，不如直接说没有。
class _ReminderSection extends ConsumerWidget {
  const _ReminderSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final soft = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final enabled = ref.watch(reminderEnabledProvider);
    final supported = !PlatformInfo.isDesktop;

    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('追番提醒', style: theme.textTheme.bodyLarge),
                    const SizedBox(height: 2),
                    Text(
                      supported
                          ? (enabled
                                ? '每天早上 9:00 检查一次；有在追的作品更新就提醒你。'
                                : '在追的作品更新当天，早上 9:00 提醒一次。')
                          : '桌面端暂不支持系统通知，这一项只在 Android 上可用。',
                      style: soft,
                    ),
                  ],
                ),
              ),
              Switch(
                value: enabled,
                onChanged: supported
                    ? (value) => _toggle(context, ref, value)
                    : null,
              ),
            ],
          ),
          if (supported && enabled) ...[
            const SizedBox(height: 8),
            Text(
              '依据本机已同步的档期与收藏计算，只排未来两周。'
              '换季或长时间不打开 App 后会自然停止——「没提醒」不等于「没更新」。',
              style: soft,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _toggle(BuildContext context, WidgetRef ref, bool value) async {
    if (!value) {
      // 关掉之后 service 会清空已排的提醒（见 `ReminderService.refresh`）。
      await ref.read(reminderEnabledProvider.notifier).setEnabled(false);
      return;
    }

    final permission = await ref
        .read(reminderSchedulerProvider)
        .requestPermission();
    if (!context.mounted) return;

    if (permission == ReminderPermission.denied) {
      // 被拒时**不要**把开关留在「开」：那会让用户以为已经生效。
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有通知权限，提醒无法开启。请在系统设置里允许通知后重试。')),
      );
      return;
    }
    if (permission == ReminderPermission.unsupported) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('这台设备不支持本地提醒')));
      return;
    }

    await ref.read(reminderEnabledProvider.notifier).setEnabled(true);
  }
}

class _CacheSection extends ConsumerWidget {
  const _CacheSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final usage = ref.watch(cacheUsageProvider);
    final data = usage.value;
    // 统计失败时不假装是 0：那会让用户以为「本来就没有缓存」。
    // 按钮保持可点——清一次本来就是安全的。
    final canClear = usage.isLoading || data == null || data.entries > 0;

    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('已缓存内容', style: theme.textTheme.bodyLarge),
                    const SizedBox(height: 2),
                    Text(
                      _describe(usage),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: canClear ? () => _confirmClear(context, ref) : null,
                child: const Text('清除'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '断网时列表与详情会回退到这些缓存，并在顶部标注上次同步时间。'
            '清除后需要联网才能重新查看，收藏与浏览历史不受影响。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  static String _describe(AsyncValue<CacheUsage> usage) {
    return switch (usage) {
      AsyncData(:final value) when value.entries == 0 => '暂无缓存',
      AsyncData(:final value) =>
        '${value.entries} 条 · 约 ${_formatBytes(value.bytes)}',
      AsyncError() => '统计失败',
      _ => '统计中…',
    };
  }

  /// 1024 进制。设置页写「约」，因为 [CacheUsage.bytes] 本身就是估算。
  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    return '${(kb / 1024).toStringAsFixed(1)} MB';
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清除离线缓存？'),
        content: const Text('清除后断网时将看不到已缓存的作品，联网后会重新缓存。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await clearWorkCache(ref);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已清除离线缓存')));
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final soft = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('版本', style: theme.textTheme.bodyLarge),
              const Spacer(),
              Text(AppConfig.version, style: soft),
            ],
          ),
          const SizedBox(height: 12),
          Text('数据来源', style: theme.textTheme.bodyLarge),
          const SizedBox(height: 2),
          Text(
            '作品与资讯来自来源站，平台只读同步，评分与简介保留来源站原值。'
            '「抓不到」不等于来源站已删除——同步失败只会让内容暂时看不到。',
            style: soft,
          ),
        ],
      ),
    );
  }
}
