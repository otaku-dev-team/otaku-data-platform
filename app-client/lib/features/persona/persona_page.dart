import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_layout.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/desktop_nav_shell.dart';
import '../../shared/widgets/section_state_view.dart';
import '../../shared/widgets/tag_chips.dart';
import 'persona_data_source.dart';
import 'persona_radar_chart.dart';
import 'persona_view_data.dart';

/// #375 阿宅画像（UI 壳）。
///
/// 对标网站 `/me/persona`：六维雷达 + 锐评 + 偏好标签 + 生成设置入口。
///
/// #401 的 `GET /api/me/profile` 已上线，但它给的是类型 / 标签权重与评分倾向，
/// 没有这里的「称号 + 锐评 + 六维」。展示口径属于 #375，本轮（#376 推荐接真数据）
/// 不改这一页，继续用 [PersonaMockDataSource] + 「界面预览」横幅标清数据来源。
///
/// 生成 / 绑定 / 语气这一排刻意「未开放」：点了没反应比明说更糟，
/// 沿用个人空间 `_SectionTile` 的口径。
class PersonaPage extends ConsumerWidget {
  const PersonaPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final insight = ref.watch(personaInsightProvider);

    return DesktopNavShell(
      child: Scaffold(
        appBar: AppBar(title: const Text('阿宅画像')),
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
                const _ShellNotice(),
                const SizedBox(height: Space.s4),
                SectionStateView<PersonaInsight>(
                  value: insight,
                  onRetry: () => ref.invalidate(personaInsightProvider),
                  skeletonHeight: 340,
                  emptyIcon: Icons.auto_awesome_outlined,
                  emptyTitle: '还没有可展示的画像',
                  emptyMessage: '等画像接口就绪、或攒够一些浏览与收藏后再来看看。',
                  isEmpty: (data) => data.dimensions.isEmpty,
                  builder: (data) => _InsightBody(data: data),
                ),
                const SizedBox(height: Space.s4),
                const _PendingActions(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 演示数据标记。**不要删**：#418 的种子脚本也要求演示数据必须标注，
/// 免得有人拿这张截图当成真实用户画像去对数。
class _ShellNotice extends StatelessWidget {
  const _ShellNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(Space.s3),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.55),
        borderRadius: Radii.circularMd(),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.science_outlined,
            size: 20,
            color: scheme.onSecondaryContainer,
          ),
          const SizedBox(width: Space.s2),
          Expanded(
            child: Text(
              '界面预览：以下为演示数据。画像页展示口径（#375）未定，暂不消费 /api/me/profile。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InsightBody extends StatelessWidget {
  const _InsightBody({required this.data});

  final PersonaInsight data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 称号。空串不当成「没称号」渲染一个空标题，直接整块不画。
        if (data.title.isNotEmpty) ...[
          Text(
            data.title,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: AppTheme.brandInk(context),
            ),
          ),
          const SizedBox(height: Space.s4),
        ],
        Card(
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.s2,
              vertical: Space.s3,
            ),
            child: PersonaRadarChart(dimensions: data.dimensions),
          ),
        ),
        const SizedBox(height: Space.s3),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(Space.s4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.format_quote_rounded,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: Space.s1),
                    Text('锐评', style: theme.textTheme.titleSmall),
                  ],
                ),
                const SizedBox(height: Space.s2),
                // 文案由服务端生成，客户端一个字都不改。
                Text(
                  data.review,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.7),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Space.s3),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(Space.s4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('偏好的题材', style: theme.textTheme.titleSmall),
                const SizedBox(height: Space.s2),
                TagChips(tags: data.topTags, maxVisible: 8),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 生成 / 绑定 / 语气设置。接口未定稿前全部不可点，但版式先摆出来，
/// 这样后端一落地就知道该往哪儿接。
class _PendingActions extends StatelessWidget {
  const _PendingActions();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _PendingTile(
            icon: Icons.link_rounded,
            title: '绑定 Bangumi / B 站',
            // null = 接口还没给，不能显示「未绑定」——那是在替用户下结论。
            subtitle: null,
          ),
          const Divider(height: 1),
          _PendingTile(
            icon: Icons.tune_rounded,
            title: '自定义锐评语气',
            subtitle: null,
          ),
          const Divider(height: 1),
          _PendingTile(
            icon: Icons.auto_awesome_rounded,
            title: '重新生成报告',
            subtitle: null,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.s4, 0, Space.s4, Space.s3),
            child: Text(
              '以上能力依赖画像生成服务，尚未开放（与已上线的画像聚合接口 #401 不是一回事）。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PendingTile extends StatelessWidget {
  const _PendingTile({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      enabled: false,
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: Text(
        '待接口',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
