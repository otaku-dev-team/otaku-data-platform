import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../shared/widgets/brand_mark.dart';
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
        SettingsSectionTitle('品牌'),
        _BrandCard(),
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

/// 品牌：站名、站点键、归属方。
///
/// 站点键平时不该出现在界面文案里，这里破例写出来：换站交付时最常见的误装
/// 就是装成上一家的包，而两个包的界面在「关于」页之外几乎一样。
class _BrandCard extends StatelessWidget {
  const _BrandCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final soft = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    // 站点键与归属方都可能没注入（编辑器里直跑），空字符串就别硬摆出来，
    // 否则界面上会留一个空白的右对齐文本、或一句「归属于 ；」。
    final siteId = AppConfig.siteId;
    final company = AppConfig.brandCompany;

    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const BrandMark(size: 40),
              const Spacer(),
              if (siteId.isNotEmpty) Text(siteId, style: soft),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            company.isEmpty
                ? '作品与资讯的版权归来源站与原权利人所有。'
                : '客户端与数据归属 $company；作品与资讯的版权归来源站与原权利人所有。',
            style: soft?.copyWith(height: 1.5),
          ),
        ],
      ),
    );
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
