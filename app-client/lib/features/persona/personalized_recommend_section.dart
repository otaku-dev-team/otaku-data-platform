import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/compact_work_card.dart';
import '../../shared/widgets/section_state_view.dart';
import 'persona_data_source.dart';
import 'persona_view_data.dart';

/// #376 首页个性化推荐区块。
///
/// - 登录用户：横排展示推荐作品 + 一句「为什么推荐给你」；
/// - 游客：**不展示个性化榜单**，只给一张登录引导卡。#376 要求的「回落默认榜」
///   由首页既有的「高分作品 / 本日新番」固定榜承担，这里不重复造第二份榜；
/// - 冷启动（`cold_start = true`）：画像为空，服务端返回的是全站高分榜，
///   标题必须改成「热门推荐」——不能把公共榜单说成是给用户算出来的。
///
/// 数据来自 [personaDataSourceProvider]：`USE_MOCK=false` 时走
/// `GET /api/me/recommend`（#402，2026-11-06 已上线），规则 key → 理由文案
/// 的映射在数据源层。客户端不自算打分（§6），`score` 不展示。
class PersonalizedRecommendSection extends ConsumerWidget {
  const PersonalizedRecommendSection({super.key});

  static const double _cardWidth = 148;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(personaFeedProvider);
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final stripHeight = CompactWorkCard.heightFor(_cardWidth, textScale) + 26;
    // 错误 / 加载态还没有数据，标题沿用「为你推荐」；拿到 cold_start 再改口。
    final coldStart = feed.hasValue && feed.requireValue.coldStart;

    return _Frame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(coldStart: coldStart),
          SectionStateView<PersonaFeed>(
            value: feed,
            onRetry: () => ref.invalidate(personaFeedProvider),
            skeletonHeight: stripHeight,
            emptyIcon: Icons.auto_awesome_outlined,
            emptyTitle: '暂时没有为你挑出作品',
            emptyMessage: '多看几部、攒点收藏，推荐会更准。',
            isEmpty: (data) => !data.isGuest && data.isEmpty,
            builder: (data) =>
                data.isGuest ? const _GuestCard() : _Strip(items: data.items),
          ),
          const SizedBox(height: Space.s5),
        ],
      ),
    );
  }
}

/// 与首页 `_Section` 同款的外框（那是私有类，跨文件用不了）。
class _Frame extends StatelessWidget {
  const _Frame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppLayout.listMaxWidth),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppLayout.pagePadding,
          ),
          child: child,
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.coldStart});

  final bool coldStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 15,
            decoration: BoxDecoration(
              color: AppTheme.brandInk(context),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              coldStart ? '热门推荐' : '为你推荐',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Text(
            coldStart ? '全站高分' : '按画像',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _Strip extends StatelessWidget {
  const _Strip({required this.items});

  final List<RecommendedWork> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final cardHeight = CompactWorkCard.heightFor(
      PersonalizedRecommendSection._cardWidth,
      textScale,
    );
    return SizedBox(
      height: cardHeight + 26,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final entry = items[index];
          return SizedBox(
            width: PersonalizedRecommendSection._cardWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CompactWorkCard(
                  work: entry.work,
                  width: PersonalizedRecommendSection._cardWidth,
                  heroTag: 'home-persona-$index',
                ),
                const SizedBox(height: 4),
                // 单行 + 省略号：固定高度容器里放 Wrap 会静默画到容器外
                // （项目里踩过），所以理由只展示第一条，不换行。
                Text(
                  entry.reasons.isEmpty ? '' : entry.reasons.first,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _GuestCard extends StatelessWidget {
  const _GuestCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(Space.s4),
        child: Row(
          children: [
            Icon(
              Icons.auto_awesome_outlined,
              size: 24,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: Space.s3),
            Expanded(
              child: Text(
                '登录后，这里会按你的口味挑作品。现在先看看大家都在追的高分榜。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: Space.s2),
            TextButton(
              onPressed: () => context.push(RoutePaths.login),
              child: const Text('登录'),
            ),
          ],
        ),
      ),
    );
  }
}
