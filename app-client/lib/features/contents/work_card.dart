import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';
import '../../data/models/work_summary.dart';
import '../../shared/widgets/cover_image.dart';
import '../../shared/widgets/rating_badge.dart';
import '../../shared/widgets/tag_chips.dart';
import '../../shared/widgets/work_type_tag.dart';

/// 列表卡片。只用列表接口给的 6 个字段，**不显示简介**——
/// 列表根本不返回 `summary`，别在这里想办法补。
class WorkCard extends StatelessWidget {
  const WorkCard({super.key, required this.work});

  final WorkSummary work;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tags = work.tags;

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppLayout.cardRadius),
        onTap: () => context.push(RoutePaths.workDetail(work.workId)),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CoverImage(url: work.coverUrl),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      work.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        WorkTypeTag(type: work.workType),
                        // 契约 6.3：没有评分就整块不渲染，不能显示 0.0。
                        RatingBadge(rating: work.mainRating, compact: true),
                      ],
                    ),
                    if (tags != null) ...[
                      const SizedBox(height: 8),
                      TagChips(tags: tags),
                    ],
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
