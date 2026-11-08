import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/desktop_nav_shell.dart';
import '../../shared/widgets/section_state_view.dart';
import 'persona_data_source.dart';
import 'persona_radar_chart.dart';
import 'persona_view_data.dart';

/// #375 阿宅画像。
///
/// 对标网站 `/me/persona`：称号 + 稀有度 + 九维雷达 + 标签解读 + 锐评。
///
/// **九维由服务端算**（`GET /api/me/profile` 的 `dimensions`，键序固定），
/// 客户端只做 0–100 → 0–1 的换算（`PersonaInsightMapper`）。2026-11-09 之前
/// 这里是客户端自造六轴，与网站口径不一致（#498），已经删掉——**别再往端上
/// 加公式**，一加就又分家了。
///
/// 生成 / 绑定 / 语气这一排刻意「未开放」：点了没反应比明说更糟，
/// 沿用个人空间 `_SectionTile` 的口径。
class PersonaPage extends ConsumerWidget {
  const PersonaPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final insight = ref.watch(personaInsightProvider);
    // 未登录时 provider 直接返回空画像（一个请求都不发），这里只决定空态说什么。
    final signedIn = ref.watch(personalizedAudienceProvider);

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
                const SizedBox(height: Space.s2),
                SectionStateView<PersonaInsight>(
                  value: insight,
                  onRetry: () => ref.invalidate(personaInsightProvider),
                  skeletonHeight: 340,
                  emptyIcon: Icons.auto_awesome_outlined,
                  emptyTitle: signedIn ? '还没有可展示的画像' : '登录后查看画像',
                  emptyMessage: signedIn
                      ? '画像来自你的浏览、收藏与点评——攒够一些记录再来看看。'
                      : '画像由你的浏览、收藏与点评算出来，登录后才会生成。',
                  isEmpty: (data) => data.dimensions.isEmpty,
                  builder: (data) => _InsightBody(data: data),
                ),
                const SizedBox(height: Space.s4),
                // #505 冷启动补标入口。画像数据不够时，这是用户唯一能主动
                // 「喂数据」的动作——不给入口，空态就只是个死胡同。
                if (signedIn) ...[
                  const _QuizEntryCard(),
                  const SizedBox(height: Space.s3),
                ],
                const _PendingActions(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InsightBody extends StatelessWidget {
  const _InsightBody({required this.data});

  final PersonaInsight data;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HeroCard(data: data),
        const SizedBox(height: Space.s3),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.s2,
              vertical: Space.s3,
            ),
            child: PersonaRadarChart(dimensions: data.dimensions),
          ),
        ),
        // 「为什么长这样」放在图下方而不是图里：图要保持干净，
        // 这句话是给「觉得图怪但说不上哪里怪」的人看的。
        for (final hint in data.hints) ...[
          const SizedBox(height: Space.s2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 14,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: Space.s1),
              Expanded(
                child: Text(
                  hint,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
        if (data.topTags.isNotEmpty) ...[
          const SizedBox(height: Space.s3),
          _TraitCard(tags: data.topTags, blurbs: data.traitBlurbs),
        ],
        if (data.review.isNotEmpty) ...[
          const SizedBox(height: Space.s3),
          _ReviewCard(review: data.review, quip: data.quip),
        ],
      ],
    );
  }
}

/// 称号卡：称号 + 代号 + 稀有度徽章。
///
/// 稀有度配色按 #490 口径（SSR 金 / SR 蓝 / R 灰 / N 浅灰 / 未标定虚线灰），
/// **不自行换色换名**——同一个用户在网站与 App 上看到的徽章必须是同一套。
class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.data});

  final PersonaInsight data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rarity = data.rarity;

    return Card(
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.primaryContainer.withValues(alpha: 0.55),
              scheme.surface.withValues(alpha: 0.0),
            ],
          ),
        ),
        padding: const EdgeInsets.fromLTRB(Space.s4, Space.s4, Space.s4, Space.s3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    data.title,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: AppTheme.brandInk(context),
                    ),
                  ),
                ),
                if (rarity != null) _RarityBadge(rarity: rarity),
              ],
            ),
            if (data.titleCode != null) ...[
              const SizedBox(height: Space.s1),
              Text(
                data.titleCode!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  letterSpacing: 1.4,
                ),
              ),
            ],
            if (rarity != null) ...[
              const SizedBox(height: Space.s2),
              Text(
                _rarityLine(rarity),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 「满地都是 · 12.3% 的人都在这」——`share = null` 时**不写 0%**。
  static String _rarityLine(PersonaRarity rarity) {
    final parts = <String>[
      if (rarity.label.isNotEmpty) rarity.label,
      if (rarity.share != null)
        '${rarity.share!.toStringAsFixed(1)}% 的人在这'
      else
        '占比未标定',
      if (rarity.note != null) rarity.note!,
    ];
    return parts.join(' · ');
  }
}

class _RarityBadge extends StatelessWidget {
  const _RarityBadge({required this.rarity});

  final PersonaRarity rarity;

  /// #490 口径：SSR 金 / SR 蓝 / R 灰 / N 浅灰 / 未标定虚线灰。
  static const Map<String, Color> _colors = <String, Color>{
    'SSR': Color(0xFFE0A800),
    'SR': Color(0xFF2B9AE0),
    'R': Color(0xFF7B8896),
    'N': Color(0xFFAAB4BF),
    '?': Color(0xFFC3CCD5),
  };

  @override
  Widget build(BuildContext context) {
    final color = _colors[rarity.tier] ?? _colors['R']!;
    final calibrated = rarity.tier != '?';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.s2, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: Radii.circularSm(),
        border: Border.all(
          color: color.withValues(alpha: calibrated ? 0.55 : 0.4),
          // 未标定用虚线在 Flutter 里要自绘，这里用低饱和描边表达「不是正式档位」。
        ),
      ),
      child: Text(
        rarity.tier,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: color,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

/// 标签 + 逐条解读（#500）。文案来自服务端 `trait_blurbs`，客户端不各抄一份。
class _TraitCard extends StatelessWidget {
  const _TraitCard({required this.tags, required this.blurbs});

  final List<String> tags;
  final Map<String, String> blurbs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.s4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('人格标签', style: theme.textTheme.titleSmall),
            const SizedBox(height: Space.s2),
            for (var i = 0; i < tags.length; i++) ...[
              if (i > 0) const SizedBox(height: Space.s2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Space.s2,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.secondaryContainer,
                      borderRadius: Radii.circularSm(),
                    ),
                    child: Text(
                      tags[i],
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(width: Space.s2),
                  Expanded(
                    child: Text(
                      blurbs[tags[i]] ?? '',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 锐评（`hero_note`）+ 收尾冷评（`final_quip`）。服务端下发，客户端一个字都不改。
class _ReviewCard extends StatelessWidget {
  const _ReviewCard({required this.review, required this.quip});

  final String review;
  final String? quip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
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
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: Space.s1),
                Text('锐评', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: Space.s2),
            Text(
              review,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.7),
            ),
            if (quip != null && quip!.isNotEmpty) ...[
              const SizedBox(height: Space.s3),
              Divider(color: scheme.outlineVariant, height: 1),
              const SizedBox(height: Space.s2),
              Text(
                quip!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                  height: 1.6,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 冷启动补标入口（#505）。点进去一部一部选「看过 / 在看 / 抛弃」，
/// 答案直接写进收藏，回来画像就有数据了。
class _QuizEntryCard extends StatelessWidget {
  const _QuizEntryCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        leading: Icon(Icons.style_outlined, color: theme.colorScheme.primary),
        title: const Text('补几部作品，画像更准'),
        subtitle: const Text('20 部快速出形状，100 部更完整'),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => context.push(RoutePaths.personaQuiz),
      ),
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
