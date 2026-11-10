import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/route_paths.dart';
import '../../core/platform_info.dart';
import '../../features/auth/auth_controller.dart';
import '../../features/auth/site_unlink_dialog.dart';
import '../../features/profile/profile_data_source.dart';

/// 账号入口（「我的」）。
///
/// **只挂在首页 AppBar 上**：手机端在搜索栏左侧（纯图标），桌面端在右侧
/// actions 里。手机底栏第 5 位的「我的」不经过本组件——那一项走的是
/// `MobileNavBar` 的 push 分支，直接进 `/me`。
///
/// 作品库 / 资讯 / 收藏 / 每日新番四页**不再挂它**：入口收敛到
/// 「首页 + 手机底栏」两处。之前为了「登录是全局动作」在四页各挂一份，
/// 结果是同一个头像出现在五个 AppBar 里，打开任何一页都先看到它。
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

    if (!PlatformInfo.isDesktop) {
      // 手机：只出现在首页 AppBar 的 leading 位。必须是纯图标——带文字的
      // 按钮放 leading 会占掉一个半图标宽，把右侧搜索框挤窄。
      // 未登录时同样进 `/me`，那一页里有登录按钮。
      return IconButton(
        tooltip: '我的',
        onPressed: () => context.push(RoutePaths.profile),
        icon: const Icon(Icons.account_circle_outlined),
      );
    }

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
      // 与个人空间身份卡共用一条规则：昵称优先、没有才回落登录名。
      // 只读 `auth.user.label` 的话，改完昵称这里还是旧名字。
      AuthStatus.signedIn => _SignedInMenu(
        label: ref.watch(profileDisplayNameProvider),
      ),
    };
  }

}


class _SignedInMenu extends ConsumerWidget {
  const _SignedInMenu({required this.label});

  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final auth = ref.watch(authControllerProvider);
    // W1 三态②：只有站点授权建的账号才有连接可断；平台账号不显示这一项。
    final isSiteIdentity = auth.user?.isSiteIdentity == true;

    return PopupMenuButton<String>(
      tooltip: '账号',
      icon: const Icon(Icons.account_circle_outlined),
      onSelected: (value) async {
        if (value == 'profile') {
          context.push(RoutePaths.profile);
          return;
        }
        if (value == 'unlink') {
          await performSiteUnlink(context, ref);
          return;
        }
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
        // 手机端点「我的」直接是这一页；桌面这轮仍是菜单，入口放这里对齐。
        const PopupMenuItem<String>(
          value: 'profile',
          child: Text('个人空间'),
        ),
        if (isSiteIdentity)
          const PopupMenuItem<String>(
            value: 'unlink',
            child: Text('断开与网站的连接'),
          ),
        const PopupMenuItem<String>(value: 'logout', child: Text('退出登录')),
      ],
    );
  }
}
