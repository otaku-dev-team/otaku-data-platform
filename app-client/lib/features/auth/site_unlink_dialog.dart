import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/design_tokens.dart';
import 'auth_controller.dart';

/// 「断开与网站的连接」的确认与执行。
///
/// 两个入口共用：个人空间的账号操作区、桌面账号菜单。抽出来只为让文案
/// 与语义只写一遍——这是最容易被改错的一处（写「已立即吊销」就是假承诺）。
///
/// 契约 `identity-linkup-contract.md` §5 三态② / `client-dev-handoff.md` §10：
/// - 断开 = **本地解绑**（清身份映射 + 撤销全部会话），**账号与数据保留**；
/// - 站点令牌平台只存哈希，调不动站点 `revoke`，最长 **1 小时**自然过期；
/// - 同一个站点身份重新授权会**接回原账号**（`user_id` 不变）；
/// - 与「注销账号」是两件事，文案必须分开。
Future<bool> confirmSiteUnlink(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('断开与网站的连接？'),
      content: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('断开后：'),
          SizedBox(height: Space.s2),
          Text('· 收藏、浏览记录与评论都保留，账号不会被删除；'),
          Text('· 这台与其他设备上的登录会一起失效，需要重新登录；'),
          Text('· 用同一个站点账号重新授权，会接回原来的账号；'),
          Text('· 站点授权最长 1 小时内自动失效。'),
          SizedBox(height: Space.s2),
          Text('这只是断开连接，不是注销账号。'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('断开连接'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// 弹确认 → 调 `POST /api/auth/site-unlink` → 提示结果。
///
/// 成功后 [AuthController.unlinkSite] 已把状态置成未登录，调用方不需要再跳转：
/// 个人空间会显示登录引导，桌面账号菜单会变回「登录」按钮。
Future<void> performSiteUnlink(BuildContext context, WidgetRef ref) async {
  final confirmed = await confirmSiteUnlink(context);
  if (!confirmed || !context.mounted) return;

  final error = await ref.read(authControllerProvider.notifier).unlinkSite();
  if (!context.mounted) return;

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        error == null
            // 不写「已立即吊销」：平台调不动站点 revoke，1 小时是准确口径。
            ? '已断开与网站的连接，站点授权将在 1 小时内自动失效'
            : '断开失败：${error.userMessage}',
      ),
    ),
  );
}
