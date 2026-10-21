import 'package:flutter/material.dart';

/// 年份文本。
///
/// 契约里 `release_year` 是**可空**的，`null` 表示来源未提供，不是 0 年。
/// 因此这里唯一的行为就是：`null` → 不占位、不渲染。
/// 用独立组件而不是到处写 `if (year != null)`，是为了让这条规则只有一处实现，
/// 将来加「按年份筛选」时也不会有人误把 null 显示成 0。
class ReleaseYearText extends StatelessWidget {
  const ReleaseYearText({
    super.key,
    required this.year,
    this.style,
  });

  final int? year;

  /// 外部可覆盖字号与颜色；不传则用 `labelMedium` + `onSurfaceVariant`。
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final value = year;
    if (value == null) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Text(
      '$value',
      style: style ??
          theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
    );
  }
}
