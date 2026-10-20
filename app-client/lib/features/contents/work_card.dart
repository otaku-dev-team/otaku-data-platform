import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';
import '../../data/models/work_summary.dart';
import '../../shared/widgets/cover_image.dart';
import '../../shared/widgets/poster_card.dart';
import '../../shared/widgets/rating_badge.dart';
import '../../shared/widgets/tag_chips.dart';
import '../../shared/widgets/work_type_tag.dart';

/// 列表卡片，形状对齐来源站的 `.work-card`：2:3 竖版海报在上、文字在下。
///
/// 只用列表接口给的 6 个字段，**不显示简介**——列表根本不返回 `summary`。
/// 站点卡片里有两行摘要和排名角标，这里都没有：接口没这两个字段，
/// 硬要做只能靠逐条请求详情，代价远大于收益。
class WorkCard extends StatelessWidget {
  const WorkCard({super.key, required this.work});

  final WorkSummary work;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 无封面时用标题首字当占位图；`characters` 取整字，emoji 不会被截半个。
    final firstChar = work.title.characters.isEmpty
        ? null
        : work.title.characters.first;

    return PosterCardShell(
      onTap: () => context.push(RoutePaths.workDetail(work.workId)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: AppLayout.posterAspect,
            child: CoverImage(
              url: work.coverUrl,
              width: double.infinity,
              height: double.infinity,
              radius: 0,
              placeholderLabel: firstChar,
            ),
          ),
          SizedBox(
            height: AppLayout.cardBodyHeight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 固定两行高度：一行标题的卡片不会比两行的矮一截。
                  SizedBox(
                    height: 40,
                    child: Text(
                      work.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      WorkTypeTag(type: work.workType),
                      const SizedBox(width: 6),
                      // 契约 6.3：没有评分就整块不渲染，不能显示 0.0。
                      RatingBadge(rating: work.mainRating, compact: true),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // 标签一行封顶：横向不滚动，超出部分裁掉，避免撑高卡片。
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const NeverScrollableScrollPhysics(),
                      child: TagChips(tags: work.tags, maxVisible: 3),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
