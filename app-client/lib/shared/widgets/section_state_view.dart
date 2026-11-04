import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/design_tokens.dart';

/// 区块级四态（错误 / 加载 / 空 / 有内容）。
///
/// 首页 `_SectionBody` 是私有组件，画像页与推荐区块跨文件用不了；
/// 这里提一份公开的，判定顺序与它保持一致：**错误优先于加载中**——
/// Riverpod 3 带重试的失败是 `AsyncLoading(error: …)`，只看 `isLoading`
/// 会把失败画成永远转不完的骨架屏。
///
/// 错误只占区块内一条窄条，不把整页变成错误页（首页既有取舍）。
class SectionStateView<T> extends StatelessWidget {
  const SectionStateView({
    super.key,
    required this.value,
    required this.builder,
    required this.onRetry,
    required this.skeletonHeight,
    this.emptyTitle = '这里还没有内容',
    this.emptyMessage,
    this.emptyIcon = Icons.inbox_outlined,
    this.isEmpty,
  });

  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback onRetry;
  final double skeletonHeight;
  final String emptyTitle;
  final String? emptyMessage;
  final IconData emptyIcon;

  /// 「有响应但没内容」由调用方判定：壳层不知道业务上的空是什么
  /// （画像看维度数，推荐看条目数）。
  final bool Function(T data)? isEmpty;

  @override
  Widget build(BuildContext context) {
    final error = value.error;
    if (error != null && !value.hasValue) {
      return _InlineError(onRetry: onRetry);
    }
    if (value.isLoading && !value.hasValue) {
      return _Skeleton(height: skeletonHeight);
    }
    final data = value.requireValue;
    if (isEmpty?.call(data) ?? false) {
      return _Empty(
        title: emptyTitle,
        message: emptyMessage,
        icon: emptyIcon,
      );
    }
    return builder(data);
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.title, required this.message, required this.icon});

  final String title;
  final String? message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 96,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: Radii.circularMd(),
      ),
      padding: const EdgeInsets.symmetric(horizontal: Space.s4),
      child: Row(
        children: [
          Icon(icon, size: 26, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: Space.s3),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                if (message != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    message!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 76,
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: Radii.circularMd(),
      ),
      padding: const EdgeInsets.symmetric(horizontal: Space.s4),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 20,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: Space.s3),
          const Expanded(
            child: Text('暂时取不到数据', maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: Radii.circularMd(),
      ),
      alignment: Alignment.center,
      child: SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          color: AppTheme.brandInk(context),
        ),
      ),
    );
  }
}
