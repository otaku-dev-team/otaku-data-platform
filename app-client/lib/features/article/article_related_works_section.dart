import 'package:flutter/material.dart';

import '../../data/models/work_summary.dart';
import '../../shared/widgets/compact_work_card.dart';

/// 资讯详情页底部的「关联作品」。
///
/// 数据来自 `ArticleDetail.relatedWorks`（后端已把来源站的 content_id
/// 解析成本地作品），**不是** `relatedWorkIds`：后者是站点号，与本地
/// `work_id` / bangumi subject id 是三套体系（见 V9、V28 与契约 ArticleDetail），
/// 客户端不解析、不拿它拼详情路由。
///
/// 边界与作品详情页的 `RelatedWorksSection` 一致：
/// - `null` / 空 → 整块不渲染，不显示「暂无关联作品」（看着像接口坏了）；
/// - 横滑而不是网格：正文是纵向长流，再接一个网格会把阅读动线断掉；
/// - 高度由 [CompactWorkCard.heightFor] 算，跟着系统字号变，不写死。
class ArticleRelatedWorksSection extends StatelessWidget {
  const ArticleRelatedWorksSection({super.key, required this.works});

  final List<WorkSummary>? works;

  /// 与作品详情页「相关作品」横滑条同宽，两处观感保持一致。
  static const double cardWidth = 116;

  @override
  Widget build(BuildContext context) {
    final items = works;
    if (items == null || items.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        Text('关联作品', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        // 来源站那块是「编辑推荐的相关作品」，不是本文主角。标一句出处，
        // 免得被读成「这篇文章讲的就是这部作品」（V9 的口径）。
        Text(
          '来源站标注的相关作品',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: CompactWorkCard.heightFor(
            cardWidth,
            MediaQuery.textScalerOf(context).scale(1),
          ),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            // 让外层纵向滚动接管，桌面端也滚得动这一行。
            primary: false,
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) => CompactWorkCard(
              work: items[index],
              width: cardWidth,
              heroTag: 'article-related-$index',
            ),
          ),
        ),
      ],
    );
  }
}
