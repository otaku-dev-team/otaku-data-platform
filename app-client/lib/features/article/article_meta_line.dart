import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// 资讯的元信息行：分类 · 发布时间 · 来源。
///
/// 三项都可能缺失，**缺哪一项就不渲染那一项**，不是拿占位符顶上：
/// 资讯的时间是「发布时间」，来源没有给时编一个「今天」出来会让人误以为
/// 这是刚出的新闻，比不显示更糟。
class ArticleMetaLine extends StatelessWidget {
  const ArticleMetaLine({
    super.key,
    this.category,
    this.publishedAt,
    this.sourceName,
  });

  final String? category;
  final String? publishedAt;
  final String? sourceName;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(context).textTheme.labelSmall;
    final date = formatArticleDate(publishedAt);
    final categoryText = category;
    final sourceText = sourceName;

    final texts = <String>[
      if (categoryText case final String value when value.isNotEmpty) value,
      ?date,
      if (sourceText case final String value when value.isNotEmpty) value,
    ];
    if (texts.isEmpty) return const SizedBox.shrink();

    return Row(
      children: [
        for (var i = 0; i < texts.length; i++) ...[
          if (i > 0) ...[
            const SizedBox(width: 8),
            // 分隔符比正文再淡一档，不然一整行「·」会把视觉重心打散。
            Text(
              '·',
              style: labelStyle?.copyWith(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(width: 8),
          ],
          _MetaText(
            text: texts[i],
            // 分类用主色，其余用次要色：一行三个字时也要能一眼找到分类。
            color: i == 0 && categoryText != null && categoryText.isNotEmpty
                ? AppTheme.brandInk(context)
                : scheme.onSurfaceVariant,
            style: labelStyle,
            // 来源名可能很长，只有它吃掉剩余宽度并省略；分类与时间保持自身宽度。
            expand: i == texts.length - 1 &&
                sourceText != null &&
                sourceText.isNotEmpty,
          ),
        ],
      ],
    );
  }
}

class _MetaText extends StatelessWidget {
  const _MetaText({
    required this.text,
    required this.color,
    required this.style,
    required this.expand,
  });

  final String text;
  final Color color;
  final TextStyle? style;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final child = Text(
      text,
      style: style?.copyWith(color: color),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return expand ? Expanded(child: child) : Flexible(child: child);
  }
}

/// ISO-8601 时间 → 展示用短文本。解析不出来返回 `null`。
///
/// 不引 `intl`：这里只需要「今天 / 昨天 / M月D日 / YYYY-MM-DD」四种形态，
/// 为一个格式函数引入整套 locale 数据不划算。
///
/// [now] 只给测试注入用，界面走默认值。
String? formatArticleDate(String? raw, {DateTime? now}) {
  if (raw == null || raw.isEmpty) return null;
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) return null;

  final local = parsed.toLocal();
  final base = now ?? DateTime.now();

  // 按「日历上的天」比，不按 24 小时：昨晚 23:50 的消息，
  // 今早 00:10 看仍然该写「昨天」。
  final today = DateTime(base.year, base.month, base.day);
  final thatDay = DateTime(local.year, local.month, local.day);
  final diffDays = today.difference(thatDay).inDays;

  if (diffDays == 0) return '今天';
  if (diffDays == 1) return '昨天';
  if (local.year == base.year) return '${local.month}月${local.day}日';
  return '${local.year}-${_pad(local.month)}-${_pad(local.day)}';
}

String _pad(int value) => value.toString().padLeft(2, '0');
