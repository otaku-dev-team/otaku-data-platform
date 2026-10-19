import 'package:flutter/material.dart';

import '../../data/models/source_rating.dart';

/// 评分徽标。
///
/// 契约 6.3：`main_rating` 为 `null` → **整块不渲染**，不得显示 `0.0`。
class RatingBadge extends StatelessWidget {
  const RatingBadge({super.key, required this.rating, this.compact = false});

  final SourceRating? rating;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final value = rating;
    if (value == null) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

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
