import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';
import '../../data/models/work_summary.dart';
import '../../shared/widgets/cover_image.dart';
import '../../shared/widgets/poster_card.dart';
import '../../shared/widgets/rating_badge.dart';
import '../../shared/widgets/release_year_text.dart';
import '../../shared/widgets/tag_chips.dart';
import '../../shared/widgets/work_type_tag.dart';
import 'contents_controller.dart';

/// 列表视图的一行：左侧 2:3 小封面，右侧标题 / 类型 / 评分 / 年份 / 标签。
///
/// 站点在列表视图里还会显示两行摘要和排名角标，这里没有——列表接口不返回
/// `summary`，契约里也没有 rank 字段。硬凑只能逐条打详情，代价远大于收益。
class WorkListTile extends ConsumerWidget {
  const WorkListTile({
    super.key,
    required this.work,
    this.showMissingRating = false,
  });

  final WorkSummary work;

  /// 无评分时是否标出「暂无评分」（W1.5 D2，同 [WorkCard]）。
  final bool showMissingRating;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final firstChar = work.title.characters.isEmpty
        ? null
        : work.title.characters.first;

    return PosterCardShell(
      onTap: () => context.push(RoutePaths.workDetail(work.workId)),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CoverImage(
              url: work.coverUrl,
              width: AppLayout.coverWidth,
              height: AppLayout.coverHeight,
              radius: AppLayout.innerRadius,
              placeholderLabel: firstChar,
              source: work.source,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    work.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      WorkTypeTag(type: work.workType),
                      const SizedBox(width: 8),
                      // 契约 6.3：没有评分不能显示 0.0。按评分排序时标出「暂无评分」。
                      RatingBadge(
                        rating: work.mainRating,
                        compact: true,
                        showMissingLabel: showMissingRating,
                      ),
                      // 列表视图比网格宽，年份靠右，与卡片视图保持同一信息顺序。
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: ReleaseYearText(
                            year: work.releaseYear,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // 列表视图比网格宽，标签多给几个；仍然只占一行，超出裁掉。
                  SizedBox(
                    height: 22,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const NeverScrollableScrollPhysics(),
                      child: TagChips(
                        tags: work.tags,
                        maxVisible: 5,
                        onTag: (tag) => ref
                            .read(contentsFilterProvider.notifier)
                            .toggleTag(tag),
                        selectedTags: ref
                            .watch(
                              contentsFilterProvider.select((f) => f.tags),
                            )
                            .toSet(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
