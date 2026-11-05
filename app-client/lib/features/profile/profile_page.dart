import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_config.dart';
import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/desktop_nav_shell.dart';
import '../../shared/widgets/user_avatar.dart';
import '../auth/auth_controller.dart';
import '../recent/recent_views_controller.dart';
import 'profile_stats.dart';

/// 个人空间。
///
/// 版式照着站点 `/me` 那一页做：一进来先是一句用途说明，然后一张身份卡
/// （头像 + 昵称 + 身份徽章 + 元信息，卡片底部压一条统计带），接一排分区
/// 入口，最后是退出登录。
///
/// **为什么从底部弹层换成独立页**：弹层只能竖着堆列表，放不下头像、统计
/// 与分区；而且「我的」在用户心里是一个地方，不是某个页面上拉出来的一张纸。
/// 换页之后这些内容才有稳定的位置，也才能从桌面侧栏直接跳过来。
///
/// 三个刻意的取舍：
///
/// 1. **统计带直接算，不做额外接口**。收藏列表本来就是全量拉的，本地数
///    三种状态即可；为此加一个 `/api/me/stats` 要把「收藏被成人遮挡过滤」
///    等口径重算一遍，且两边迟早会不一致。
/// 2. **数字拿不到就显示「—」**，不写 0。未登录时「0 条收藏」是谎话，
///    会让人以为收藏没了（铁律 3：抓不到 ≠ 已删除）。
/// 3. **资讯收藏 / 作品申请放进来但标「未开放」**。站点有这四个分区，
///    版式对齐才看得懂缺的是哪一块；但按钮不可点——点了没反应比明说更糟。
class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final stats = ref.watch(profileStatsProvider).value;
    // 浏览记录是纯本地的，未登录也有（进的是 guest 桶），所以不跟登录态走。
    final viewed = ref.watch(recentViewsProvider).length;

    return DesktopNavShell(
      child: Scaffold(
        appBar: AppBar(title: const Text('个人空间')),
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
                _IdentityCard(auth: auth, stats: stats, viewed: viewed),
                const SizedBox(height: Space.s4),
                _SectionCard(auth: auth, stats: stats, viewed: viewed),
                const SizedBox(height: Space.s3),
                // 设置单独一张卡：它是**设备级**的（主题、缓存），未登录也要能进，
                // 混进上面那排「内容分区」里会让人以为跟账号绑在一起。
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: _SectionTile(
                    icon: Icons.settings_outlined,
                    title: '设置',
                    subtitle: '外观、缓存与应用信息',
                    onTap: () => context.push(RoutePaths.settings),
                  ),
                ),
                const SizedBox(height: Space.s5),
                _SessionFooter(auth: auth),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 页面顶部那句说明。站点原文更长（还提到「作品申请」与「账号设置」），
/// 手机上压成一行半，只留下「哪些东西在这里」这一层信息。
class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      '收藏状态、浏览记录只属于你本人；账号与界面设置在同一处。',
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// 身份卡：头像 + 昵称 + 徽章 + 元信息，底部一条统计带。
class _IdentityCard extends StatelessWidget {
  const _IdentityCard({
    required this.auth,
    required this.stats,
    required this.viewed,
  });

  final AuthState auth;
  final ProfileStats? stats;
  final int viewed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final user = auth.user;
    final signedIn = auth.isSignedIn;
    final checking = auth.status == AuthStatus.checking;

    final label = signedIn ? user!.label : (checking ? '正在读取账号…' : '未登录');
    final badge = signedIn ? '已登录' : (checking ? '读取中' : '未登录');
    final meta = signedIn
        ? '已连接 ${AppConfig.appName} 账号 · 收藏在设备间同步'
        : (checking ? '稍等一下' : '登录后收藏可在手机与桌面同步');
    // 头像用昵称首字，比一个通用小人更像「我」；抽成 UserAvatar 后，
    // #378 第二层的 avatar_url 落地时只要把 URL 传进去，这里不用改。
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(Space.s4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                UserAvatar(label: label),
                const SizedBox(width: Space.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Wrap 而不是 Row：320 宽 + 双倍字号时昵称会把徽章挤出去，
                      // 这里折行比截断好读。
                      Wrap(
                        spacing: Space.s2,
                        runSpacing: Space.s1,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(label, style: theme.textTheme.titleLarge),
                          _Badge(text: badge, highlighted: signedIn),
                        ],
                      ),
                      const SizedBox(height: Space.s1),
                      Text(
                        meta,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
                const SizedBox(height: Space.s3),
                const Divider(height: 1),
                const SizedBox(height: Space.s3),
                _StatsRow(
                  collected: stats?.collected,
                  viewed: viewed,
                  watched: stats?.watched,
                  wanted: stats?.wanted,
                ),
                // 编辑资料放在身份卡底部，而不是挤进上面那行：窄屏 + 双倍字号时
                // 昵称、徽章再加一个按钮会折得很难读。未登录不给入口，
                // 编辑页自己也有登录引导，别在两处各写一套。
                if (signedIn) ...[
                  const SizedBox(height: Space.s1),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => context.push(RoutePaths.profileEdit),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('编辑资料'),
                    ),
                  ),
                ],
          ],
        ),
      ),
    );
  }
}

/// 统计带：四项横排，中间用细竖线分隔（站点用 `::before` 画线，省掉四张卡的边框）。
class _StatsRow extends StatelessWidget {
  const _StatsRow({
    required this.collected,
    required this.viewed,
    required this.watched,
    required this.wanted,
  });

  final int? collected;
  final int viewed;
  final int? watched;
  final int? wanted;

  @override
  Widget build(BuildContext context) {
    final divider = Container(
      width: 1,
      height: 26,
      color: Theme.of(context).colorScheme.outlineVariant,
    );
    return Row(
      children: [
        _Stat(value: collected, label: '收藏'),
        divider,
        _Stat(value: viewed, label: '浏览'),
        divider,
        _Stat(value: watched, label: '看过'),
        divider,
        _Stat(value: wanted, label: '想看'),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  /// `null` = 数字算不出来，显示「—」。不允许在这里回落成 0。
  final int? value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value?.toString() ?? '—',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              // 等宽数字：否则从「—」变成「4」时整条会左右抖一下。
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.highlighted});

  final String text;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = highlighted
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final foreground = highlighted
        ? scheme.onPrimaryContainer
        : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.s2, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(Space.s3),
      ),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: foreground),
      ),
    );
  }
}

/// 分区入口。站点这里是一排下划线 tab，手机上一屏塞四个 tab 再叠内容太挤，
/// 改成竖排的分区列表——顺序、名称、计数与站点一一对应。
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.auth,
    required this.stats,
    required this.viewed,
  });

  final AuthState auth;
  final ProfileStats? stats;
  final int viewed;

  @override
  Widget build(BuildContext context) {
    final signedIn = auth.isSignedIn;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _SectionTile(
            icon: Icons.bookmark_border_rounded,
            title: '作品收藏',
            subtitle: signedIn ? '收藏过的作品与观看状态' : '登录后可以查看',
            count: signedIn ? stats?.collected : null,
            // 未登录也放行：收藏页自己会显示登录引导，别在两处各写一套。
            onTap: () => context.push(RoutePaths.collections),
          ),
          const Divider(height: 1),
          _SectionTile(
            icon: Icons.history_rounded,
            title: '浏览记录',
            subtitle: '这台设备上看过的作品',
            count: viewed,
            onTap: () => context.push(RoutePaths.recentHistory),
          ),
          const Divider(height: 1),
          _SectionTile(
            icon: Icons.auto_awesome_outlined,
            title: '阿宅画像',
            subtitle: '六维雷达、锐评与口味偏好',
            onTap: () => context.push(RoutePaths.persona),
          ),
          const Divider(height: 1),
          // #378：账号数据的另一个视图。放这里而不是设置里——设备是「这个账号
          // 登录过哪里」，跟主题、缓存那种设备级设置不是一回事。
          _SectionTile(
            icon: Icons.devices_other_outlined,
            title: '登录设备',
            subtitle: '登记过推送的设备，可解绑',
            onTap: () => context.push(RoutePaths.devices),
          ),
          const Divider(height: 1),
          const _SectionTile(
            icon: Icons.article_outlined,
            title: '资讯收藏',
            subtitle: '收藏的资讯文章',
          ),
          const Divider(height: 1),
          const _SectionTile(
            icon: Icons.assignment_outlined,
            title: '作品申请',
            subtitle: '提交想看的作品条目',
          ),
        ],
      ),
    );
  }
}

class _SectionTile extends StatelessWidget {
  const _SectionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.count,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  /// 计数。`null` = 这行不报数字（设置这类入口），不是「0 条」。
  final int? count;

  /// `null` = 这个分区还没有（显示「未开放」且不可点）。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unimplemented = onTap == null;
    return ListTile(
      enabled: !unimplemented,
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: unimplemented
          ? Text(
              '未开放',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 没有计数的行（比如「设置」）就不占那块宽度，只留箭头。
                if (count != null) ...[
                  Text(
                    count.toString(),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: Space.s1),
                ],
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
      onTap: onTap,
    );
  }
}

/// 底部：已登录给退出登录（二次确认），未登录给登录入口。
class _SessionFooter extends ConsumerWidget {
  const _SessionFooter({required this.auth});

  final AuthState auth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    if (!auth.isSignedIn) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton(
            onPressed: () => context.push(RoutePaths.login),
            child: const Text('登录'),
          ),
          const SizedBox(height: Space.s3),
          Text(
            '不登录也能浏览；收藏与账号相关的功能需要登录。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        // 两个动作并排：登出是日常动作，注销是不可逆动作，放同一行既省纵向空间
        // （下面还有一句说明要显示），也让「注销」自然显得更次要。
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: Space.s2,
          children: [
            TextButton.icon(
              onPressed: auth.submitting
                  ? null
                  : () => _confirmLogout(context, ref),
              icon: const Icon(Icons.logout_rounded),
              label: const Text('退出登录'),
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
            ),
            TextButton(
              onPressed: auth.submitting
                  ? null
                  : () => _confirmDeleteAccount(context, ref),
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.onSurfaceVariant,
                textStyle: theme.textTheme.bodySmall,
              ),
              child: const Text('注销账号'),
            ),
          ],
        ),
        const SizedBox(height: Space.s2),
        Text(
          '浏览记录只存在这台设备上，退出登录不会清空。',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('退出当前账号？'),
        content: const Text('已同步的收藏会保留，再次登录即可查看。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('退出登录'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(authControllerProvider.notifier).logout();
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已退出登录')));
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('退出登录失败，请稍后重试')));
    }
  }

  /// 注销账号（#378）。文案照契约 `DELETE /api/me` 的语义写，不夸大也不含糊：
  /// 账号不能再登录、用户名不释放、评论保留但署名为「已注销用户」。
  Future<void> _confirmDeleteAccount(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('注销这个账号？'),
        content: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('注销后：'),
            SizedBox(height: Space.s2),
            Text('· 无法再用这个账号登录，用户名也不会释放；'),
            Text('· 已发布的评论会保留，作者显示为「已注销用户」；'),
            Text('· 收藏、浏览记录等账号数据会一并清除；'),
            Text('· 这台与其他设备上的登录会立刻失效。'),
            SizedBox(height: Space.s2),
            Text('此操作不可撤销。'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('注销账号'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final error = await ref.read(authControllerProvider.notifier).deleteAccount();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          error == null ? '账号已注销' : '注销失败：${error.message}',
        ),
      ),
    );
  }
}
