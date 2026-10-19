import 'package:flutter/material.dart';

import '../../core/network/api_exception.dart';

/// 错误状态。契约第 7 节：错误必须有明确提示 + 重试入口，不能静默失败。
///
/// [onRetry] 传 `null` 时不显示重试按钮——详情页拿到 404 就是这种情况，
/// 契约 6.2 明确要求"提示后返回列表，不自动重试"。
class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.error,
    this.onRetry,
    this.retryLabel = '重试',
    this.title,
    this.action,
  });

  final ApiException error;
  final VoidCallback? onRetry;
  final String retryLabel;

  /// 覆盖默认标题，例如详情 404 用"作品不存在"。
  final String? title;

  /// 重试按钮之外的附加操作，例如"返回列表"。
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isNetworkError =
        error.code == ApiErrorCode.network || error.code == ApiErrorCode.timeout;
    final resolvedTitle =
        title ?? (isNetworkError ? '网络好像不太行' : '加载失败');
    final message = error.userMessage;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isNetworkError ? Icons.wifi_off_rounded : Icons.error_outline,
              size: 48,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              resolvedTitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            // 标题和正文重复时只显示一次，例如 404 的"作品不存在"。
            if (message.isNotEmpty && message != resolvedTitle) ...[
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onRetry != null)
                  FilledButton.tonal(
                    onPressed: onRetry,
                    child: Text(retryLabel),
                  ),
                if (onRetry != null && action != null) const SizedBox(width: 12),
                ?action,
              ],
            ),
          ],
        ),
      ),
    );
  }
}
