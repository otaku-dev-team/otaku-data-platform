import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../update/update_controller.dart';
import '../update/update_dialog.dart';
import 'settings_widgets.dart';

/// 关于：版本、检查更新、数据来源声明。
class AboutSettingsPage extends ConsumerWidget {
  const AboutSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const SettingsSubPage(
      title: '关于',
      children: [
        SettingsSectionTitle('版本'),
        _VersionCard(),
        SettingsSectionTitle('数据来源'),
        _SourceCard(),
      ],
    );
  }
}

class _VersionCard extends ConsumerWidget {
  const _VersionCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final soft = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final update = ref.watch(updateControllerProvider);
    final checking = update.phase == UpdatePhase.checking;

    return SettingsCard(
      child: Row(
        children: [
          Text('当前版本', style: theme.textTheme.bodyLarge),
          const Spacer(),
          Text(AppConfig.version, style: soft),
          const SizedBox(width: 8),
          if (AppConfig.useMock)
            Text('Mock 模式', style: soft)
          else
            TextButton(
              onPressed: checking ? null : () => _check(context, ref),
              child: checking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('检查更新'),
            ),
        ],
      ),
    );
  }

  Future<void> _check(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final controller = ref.read(updateControllerProvider.notifier);

    final manifest = await controller.check(manual: true);
    if (!context.mounted) return;

    if (manifest == null) {
      final state = ref.read(updateControllerProvider);
      final message = state.phase == UpdatePhase.error
          ? (state.error ?? '检查更新失败')
          : '已是最新版本';
      // 检查失败/已是最新都不该在状态里留 error，避免下次启动误判。
      controller.reset();
      messenger.showSnackBar(SnackBar(content: Text(message)));
      return;
    }

    await showUpdateDialog(context, ref, manifest);
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SettingsCard(
      child: Text(
        '作品与资讯来自来源站，平台只读同步，评分与简介保留来源站原值。'
        '「抓不到」不等于来源站已删除——同步失败只会让内容暂时看不到。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          height: 1.5,
        ),
      ),
    );
  }
}
