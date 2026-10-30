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
    this.showOverflowCount = false,
    this.singleLine = false,
    this.onTag,
    this.selectedTags = const <String>{},
  });

  final List<String>? tags;

  /// 最多展示几个。超出部分默认直接不展示，避免卡片被撑高。
  final int maxVisible;

  /// 超出 [maxVisible] 时，最后一个位置换成 `+N`。
  ///
  /// 用在**高度固定、不能换行**的位置（列表磁贴的单行标签区）：直接裁掉
  /// 会让用户以为标签就这些，而且断在半个字上像渲染坏了。
  /// 详情页这类可以自然换行的地方保持 `false`，没必要藏。
  final bool showOverflowCount;

  /// 强制单行（不换行）。
  ///
  /// `Wrap` 在宽度不够时会折行：放进**固定高度**的容器（列表磁贴那条 22px
  /// 标签行）后，第二行会直接画到容器外、压住下一条卡片——真机上就是
  /// 320 宽下列表磁贴的标签压到下一张卡上。这类位置必须用 `Row` 排一行，
  /// 超出部分由调用方用横向滚动 / 裁切处理。
  ///
  /// 高度自由的场景（详情页、资讯正文）保持 `false`，让标签自然换行。
  final bool singleLine;

  /// 点了某个标签就回调它；`null` 表示纯展示。
  final ValueChanged<String>? onTag;

  /// 当前参与筛选的标签集合。传了会把命中的标签标出来——否则筛完之后
  /// 卡片上的标签和没筛时长得一样，用户不知道自己处在筛选状态。
  ///
  /// 是集合而不是单个：多标签 AND 筛选时，一张卡片上可能有多个标签同时生效，
  /// 只标一个会让用户以为另一个没起作用。
  final Set<String> selectedTags;

  @override
  Widget build(BuildContext context) {
    final values = tags;
    if (values == null || values.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final limit = showOverflowCount && values.length > maxVisible
        ? (maxVisible > 1 ? maxVisible - 1 : 0)
        : maxVisible;
    final visible = values.take(limit);
    final hidden = values.length - limit;

    final chips = <Widget>[
      for (final tag in visible)
        _Tag(
          label: tag,
          textStyle: textTheme.labelSmall,
          scheme: scheme,
          selected: selectedTags.contains(tag),
          onTap: onTag,
        ),
      // `+N` 只是提示还有多少，不参与筛选，所以不给 onTap。
      if (hidden > 0)
        _Tag(
          label: '+$hidden',
          textStyle: textTheme.labelSmall,
          scheme: scheme,
          selected: false,
          onTap: null,
        ),
    ];

    if (singleLine) {
      // 一行到底：Row 不会折行，超宽由外层的横向滚动/裁切兜住。
      return Row(mainAxisSize: MainAxisSize.min, spacing: 6, children: chips);
    }

    return Wrap(spacing: 6, runSpacing: 6, children: chips);
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