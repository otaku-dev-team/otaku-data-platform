import 'package:flutter/material.dart';

/// 标签区。契约 6.3：`tags` 为 `null` 或 `[]` → **不渲染标签区**。
/// 这里把两种空值都当成"没有"，直接返回空盒子，调用方不用再判一次。
///
/// [onTag] 传 `null` 时是纯展示（详情页的标签不参与筛选）；
/// 传了就变成筛选入口——列表卡片上的标签可直接点，点了就按该标签筛。
/// 这也是标签筛选最自然的入口：用户想「看同题材的」时，他看到的就是标签本身。
class TagChips extends StatelessWidget {
  const TagChips({
    super.key,
    required this.tags,
    this.maxVisible = 4,
    this.onTag,
    this.selectedTag,
  });

  final List<String>? tags;

  /// 来源每条最多 5 个，超出部分不展示，避免卡片被撑高。
  final int maxVisible;

  /// 点了某个标签就回调它；`null` 表示纯展示。
  final ValueChanged<String>? onTag;

  /// 当前正在筛选的标签。传了会把它标出来——否则筛完之后卡片上的标签
  /// 和没筛时长得一样，用户不知道自己处在筛选状态。
  final String? selectedTag;

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
          _Tag(
            label: tag,
            textStyle: textTheme.labelSmall,
            scheme: scheme,
            selected: tag == selectedTag,
            onTap: onTag,
          ),
      ],
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({
    required this.label,
    required this.textStyle,
    required this.scheme,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final TextStyle? textStyle;
  final ColorScheme scheme;
  final bool selected;
  final ValueChanged<String>? onTap;

  @override
  Widget build(BuildContext context) {
    // 选中的标签用「实心 + 反色」而不是只换个边框色：边框色在低对比度屏幕上
    // 几乎看不出差别，而这里是「我处在筛选状态」的唯一提示。
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: selected ? scheme.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: selected ? scheme.primary : scheme.outlineVariant,
        ),
      ),
      child: Text(
        label,
        style: textStyle?.copyWith(
          color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
        ),
      ),
    );

    final callback = onTap;
    if (callback == null) return chip;

    // 可点时给按压反馈，否则用户会以为标签只是文字。
    return InkWell(
      onTap: () => callback(label),
      borderRadius: BorderRadius.circular(999),
      child: chip,
    );
  }
}