import 'package:flutter/material.dart';

import 'brand_mark.dart';

/// 空状态。列表无数据、搜索无结果、详情不存在都用它，保证文案风格一致。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    this.message,
    this.icon = Icons.inbox_outlined,
    this.action,
    this.showBrand = true,
  });

  final String title;
  final String? message;
  final IconData icon;
  final Widget? action;

  /// 底部是否压一行站点署名。
  ///
  /// 空态是**停留**的状态（用户会看着它想下一步做什么），也是整屏最空的时候，
  /// 品牌放在这里不抢内容、又能回答「这是哪个客户端」。嵌在区块里、
  /// 高度很紧的地方可以关掉（`showBrand: false`）。
  final bool showBrand;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = this.message;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 20), action!],
            if (showBrand) ...[
              const SizedBox(height: 28),
              const BrandSign(),
            ],
          ],
        ),
      ),
    );
  }
}
