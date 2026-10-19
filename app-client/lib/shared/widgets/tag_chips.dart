import 'package:flutter/material.dart';

/// 标签区。契约 6.3：`tags` 为 `null` 或 `[]` → **不渲染标签区**。
/// 这里把两种空值都当成"没有"，直接返回空盒子，调用方不用再判一次。
class TagChips extends StatelessWidget {
  const TagChips({super.key, required this.tags, this.maxVisible = 4});

  final List<String>? tags;

  /// 来源每条最多 5 个，超出部分不展示，避免卡片被撑高。
  final int maxVisible;

  @override
  Widget build(BuildContext context) {
    final values = tags;
    if (values == null || values.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final visible = values.take(maxVisible);

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final tag in visible)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Text(
              tag,
              style: textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
