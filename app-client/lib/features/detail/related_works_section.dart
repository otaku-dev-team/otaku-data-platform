import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';
import '../../data/models/work_summary.dart';
import '../../shared/widgets/cover_image.dart';
import '../../shared/widgets/rating_badge.dart';
import 'work_detail_controller.dart';

/// 详情页底部的「相关作品」。契约 `GET /api/works/{work_id}/related`。
///
/// 三条边界决定这个区块的形状：
/// - **作品没标签** → 服务端返回空结果（不是错误），此时**整块不渲染**，
///   而不是显示「暂无推荐」——后者会让人以为是接口坏了。
/// - **请求失败** → 同样整块不渲染。推荐是锦上添花，不能因为拿不到它
///   就把作品本身的信息也拖进错误态。
/// - **作品不存在** → 404 由详情页整体处理，这里不会单独跑到。
///
/// 卡片是横向滚动而不是网格：正文已经是纵向长流，再接一个网格会把
/// 「相关内容」变成第二个列表，阅读动线断掉。
class RelatedWorksSection extends ConsumerWidget {
  const RelatedWorksSection({super.key, required this.workId});

  final String workId;

  static const double _cardWidth = 116;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final related = ref.watch(relatedWorksProvider(workId));

    // 加载中给一条与卡片等高的占位，避免区块"先不显示、再突然顶出来"抖动。
    if (related.isLoading) {
      return const SizedBox(height: 250, child: _RelatedSkeleton());
    }

    final data = related.value;
    // 失败或无内容：整块不渲染（理由见类注释）。错误不静默——详情页另有
    // 错误出口，这里的取舍是"少一个区块"而不是"显示一个坏区块"。
    if (related.hasError || data == null || data.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Row(
          children: [
            Text('相关作品', style: theme.textTheme.titleMedium),
            const SizedBox(width: 8),
            // basis_tags 是服务端**实际参与匹配**的标签，拿来说明"为什么是这些"。
            // 为空时标题后面不跟理由，而不是编一个。
            if (data.basisTags.isNotEmpty)
              Expanded(
                child: Text(
                  '同题材：${data.basisTags.join('、')}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 250,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            // 横向列表也要能被外层滚动接管，否则在桌面端滚不动这一行。
            primary: false,
            itemCount: data.items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) =>
                _RelatedCard(work: data.items[index], width: _cardWidth),
          ),
        ),
      ],
    );
  }
}

/// 一张相关作品卡。竖版海报 + 两行标题 + 评分，字段与列表卡片一致
/// （列表接口不返回简介，这里也不可能有）。
class _RelatedCard extends StatelessWidget {
  const _RelatedCard({required this.work, required this.width});

  final WorkSummary work;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final firstChar = work.title.characters.isEmpty
        ? null
        : work.title.characters.first;

    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppLayout.cardRadius),
        onTap: () => context.push(RoutePaths.workDetail(work.workId)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CoverImage(
              url: work.coverUrl,
              width: width,
              height: width / AppLayout.posterAspect,
              radius: AppLayout.cardRadius,
              placeholderLabel: firstChar,
            ),
            const SizedBox(height: 6),
            Text(
              work.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 4),
            // 契约 6.3：没有评分整块不渲染，不显示 0.0。
            if (work.mainRating != null)
              RatingBadge(rating: work.mainRating, compact: true),
          ],
        ),
      ),
    );
  }
}

/// 加载态占位。不做脉冲动画：详情页已经有了骨架屏，这里再动一下反而抢视线。
class _RelatedSkeleton extends StatelessWidget {
  const _RelatedSkeleton();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      primary: false,
      itemCount: 3,
      separatorBuilder: (_, _) => const SizedBox(width: 10),
      itemBuilder: (_, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: RelatedWorksSection._cardWidth,
            height: RelatedWorksSection._cardWidth / AppLayout.posterAspect,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(AppLayout.cardRadius),
            ),
          ),
          const SizedBox(height: 6),
          Container(
            width: RelatedWorksSection._cardWidth - 20,
            height: 12,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ],
      ),
    );
  }
}
