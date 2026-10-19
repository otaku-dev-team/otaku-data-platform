import 'package:flutter/material.dart';

import '../../data/models/work_type.dart';

/// 类型角标。契约 2.1 只有四种取值，未知值降级显示"其他"，
/// 不隐藏——隐藏会让人以为这条数据没有类型。
class WorkTypeTag extends StatelessWidget {
  const WorkTypeTag({super.key, required this.type});

  final WorkType type;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        type.label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
