import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/route_paths.dart';
import '../../features/auth/auth_controller.dart';

/// 账号入口。
///
/// **放在作品库的 AppBar 上**，不能只挂在收藏页里：账号是全局状态，登录
/// 不该藏在「先点收藏、再点右上角」两个跳转之后。收藏页同一个组件复用，
/// 两处的三态表现也就不会各写一套。
///
/// 三态与 [AuthStatus] 一一对应：
/// - `checking`：小转圈——既不能先说「已登录」，也不该闪一下「登录」按钮；
/// - `signedOut`：登录按钮；
/// - `signedIn`：账号菜单（显示昵称/用户名 + 退出登录）。
class AccountMenuButton extends ConsumerWidget {
  const AccountMenuButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);

    return switch (auth.status) {
      AuthStatus.checking => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      AuthStatus.signedOut => TextButton.icon(
        onPressed: () => context.push(RoutePaths.login),
        icon: const Icon(Icons.person_outline_rounded, size: 18),
        label: const Text('登录'),
      ),
      AuthStatus.signedIn => _SignedInMenu(label: auth.user!.label),
    };
  }
}

class _SignedInMenu extends ConsumerWidget {
  const _SignedInMenu({required this.label});

  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return PopupMenuButton<String>(
      tooltip: '账号',
      icon: const Icon(Icons.account_circle_outlined),
      onSelected: (value) async {
        if (value != 'logout') return;
        // 只结束当前会话：桌面端不受影响（C9）。
        await ref.read(authControllerProvider.notifier).logout();
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已退出登录')));
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          enabled: false,
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(value: 'logout', child: Text('退出登录')),
      ],
    );
  }
}
