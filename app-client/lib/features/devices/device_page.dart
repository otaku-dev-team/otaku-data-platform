import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';
import '../../core/theme/design_tokens.dart';
import '../../data/models/device.dart';
import '../../shared/widgets/desktop_nav_shell.dart';
import '../../shared/widgets/section_state_view.dart';
import '../auth/auth_controller.dart';
import 'device_controller.dart';

/// 登录设备（二级页，挂在 `/me/devices`）。
///
/// 对齐网站「账号安全」里的设备列表：能看见哪些设备登记过推送、什么时候登记的、
/// 哪台已经停用，并能把不认识的设备解绑。
///
/// 三个刻意的取舍：
///
/// 1. **不标「本机」**。契约里没有「当前设备」标记，客户端也没保存自己的
///    `device_id`；硬猜一个会把用户引到「解绑了自己」这种最坏结果。宁可都不标。
/// 2. **解绑要二次确认**，但文案不说「不可恢复」——重新登录/重装会再登记，
///    说成永久删除是吓唬人。
/// 3. **没有「全部解绑」**。一次清空所有设备听起来爽，实际最容易误触，
///    而且真出事时用户要的是「踢掉那一台」，不是「把自己也踢了」。
class DevicePage extends ConsumerWidget {
  const DevicePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final devices = ref.watch(deviceListControllerProvider);

    return DesktopNavShell(
      child: Scaffold(
        appBar: AppBar(title: const Text('登录设备')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppLayout.listMaxWidth),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                AppLayout.pagePadding,
                Space.s2,
                AppLayout.pagePadding,
                Space.s6,
              ),
              children: [
                const _Intro(),
                const SizedBox(height: Space.s4),
                if (!auth.isSignedIn)
                  const _SignInPrompt()
                else
                  SectionStateView<List<Device>>(
                    value: devices,
                    skeletonHeight: 180,
                    onRetry: () =>
                        ref.read(deviceListControllerProvider.notifier).refresh(),
                    isEmpty: (list) => list.isEmpty,
                    emptyTitle: '还没有登记过设备',
                    emptyMessage: '登录并开启推送后，这台设备会出现在这里。',
                    emptyIcon: Icons.devices_other_outlined,
                    builder: (list) => _DeviceList(devices: list),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      '这里列出该账号登记过推送的设备。不认识的设备可以解绑，解绑后它不再收到推送。',
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _SignInPrompt extends StatelessWidget {
  const _SignInPrompt();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.s4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('登录后查看', style: theme.textTheme.titleMedium),
            const SizedBox(height: Space.s1),
            Text(
              '设备列表属于账号数据，换账号不会看到别人的设备。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Space.s3),
            FilledButton(
              onPressed: () => context.push(RoutePaths.login),
              child: const Text('登录'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceList extends ConsumerWidget {
  const _DeviceList({required this.devices});

  final List<Device> devices;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < devices.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _DeviceTile(device: devices[i]),
          ],
        ],
      ),
    );
  }
}

class _DeviceTile extends ConsumerWidget {
  const _DeviceTile({required this.device});

  final Device device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final meta = <String>[
      device.platformLabel,
      device.providerLabel,
      if (device.createdAt != null) '登记于 ${_formatDate(device.createdAt!)}',
    ].join(' · ');

    return ListTile(
      leading: Icon(
        switch (device.platform) {
          'android' => Icons.android_rounded,
          'windows' => Icons.desktop_windows_outlined,
          'ios' => Icons.phone_iphone_rounded,
          _ => Icons.devices_other_outlined,
        },
      ),
      title: Row(
        children: [
          Flexible(child: Text(device.platformLabel)),
          if (!device.enabled) ...[
            const SizedBox(width: Space.s2),
            Text(
              '已停用',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(meta),
      trailing: TextButton(
        onPressed: () => _confirmRevoke(context, ref),
        style: TextButton.styleFrom(foregroundColor: scheme.error),
        child: const Text('解绑'),
      ),
    );
  }

  Future<void> _confirmRevoke(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('解绑这台设备？'),
        content: Text(
          '解绑后 ${device.platformLabel} 不再收到这个账号的推送。'
          '重新登录或开启推送时可以再登记回来。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('解绑'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final error = await ref
        .read(deviceListControllerProvider.notifier)
        .revoke(device.deviceId);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error == null ? '已解绑' : '解绑失败：${error.message}'),
      ),
    );
  }

  static String _formatDate(DateTime value) {
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return '${value.year}-$month-$day';
  }
}
