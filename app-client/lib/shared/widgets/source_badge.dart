import 'package:flutter/material.dart';

/// 来源标识角标：这条记录来自哪个来源站。
///
/// 存在的理由只有一条（W1.5 D3）：跨源同名作品在列表里长得一模一样，
/// 用户会把两部不同记录当成同一部。把来源写在封面上，两条同名记录就分得开了。
///
/// 三条边界：
/// 1. **只显示，不解释**。它不参与任何归并判断，也不暗示两条记录有关联 ——
///    归并属 E1 / W2 的范畴，要过三人确认才动（齐平原则：目录范围是适配配置，不是产品语义）。
/// 2. **不做取值映射**。`source` 是什么就显示什么（`bangumi` 就是 `bangumi`），
///    客户端不认识新来源时不必发版，也不替产品发明「本站 / 第三方」的说法。
/// 3. **可辨识但不抢戏**。半透明深色底 + 白字贴在封面左下角，
///    不占卡片正文的高度 —— `WorkCard` 的正文高度是按字号量死的，多一行就溢出。
class SourceBadge extends StatelessWidget {
  const SourceBadge({super.key, required this.source});

  final String source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        source,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(
          color: Colors.white,
          height: 1.2,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
