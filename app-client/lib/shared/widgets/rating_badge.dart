import 'package:flutter/material.dart';

import '../../data/models/source_rating.dart';

/// 评分徽标。
///
/// 契约 6.3：`main_rating` 为 `null` → **不得显示 `0.0`**。默认整块不渲染。
///
/// [showMissingLabel] 打开时，无评分改为渲染「暂无评分」四个字（W1.5 D2）：
/// 只在「按评分排序」这种上下文里开——那时无评分条目会沉到底部，
/// 什么都不显示会被读成「这条加载失败了」，而不是「这条本来就没分」。
class RatingBadge extends StatelessWidget {
  const RatingBadge({
    super.key,
    required this.rating,
    this.compact = false,
    this.showMissingLabel = false,
  });

  final SourceRating? rating;
  final bool compact;

  /// 无评分时是否显示「暂无评分」。为 `false` 时整块不渲染（契约默认行为）。
  ///
  /// 只标注「没有分」，**不写 `0.0` 也不画空心星**：那两种都会被读成评了零分。
  final bool showMissingLabel;

  @override
  Widget build(BuildContext context) {
    final value = rating;
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (value == null) {
      if (!showMissingLabel) return const SizedBox.shrink();
      return Text(
        '暂无评分',
        style: (compact ? textTheme.labelSmall : textTheme.labelMedium)
            ?.copyWith(color: scheme.onSurfaceVariant.withValues(alpha: 0.75)),
      );
    }

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.star_rounded,
            size: compact ? 14 : 16,
            color: scheme.onSecondaryContainer,
          ),
          const SizedBox(width: 2),
          Text(
            value.display,
            style: (compact ? textTheme.labelMedium : textTheme.labelLarge)
                ?.copyWith(
                  color: scheme.onSecondaryContainer,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}
