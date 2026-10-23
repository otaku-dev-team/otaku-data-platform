import 'package:flutter/material.dart';

/// 离线提示条。
///
/// **存在的理由**：后端不可达时我们展示本地缓存（铁律 3 的快照语义）。
/// 但缓存是**旧数据**——用户必须知道，否则会把它当成最新内容来判断。
/// 铁律 3 的原话是「展示缓存 + 标注上次同步，绝不让用户以为作品没了」，
/// 同一个道理反过来也成立：也不能让用户以为缓存是新的。
///
/// [cachedAt] 为 null 时只说「离线」，不给具体时间——那说明
/// 拿不到缓存的写入时刻（不该发生，但宁可少说也不要编一个时间）。
class OfflineNotice extends StatelessWidget {
  const OfflineNotice({super.key, this.cachedAt, this.onRetry});

  /// 缓存写入时刻。为 null 时不显示时间。
  final DateTime? cachedAt;

  /// 点了能重新拉一次。传 null 则不显示按钮。
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final at = cachedAt;

    return Container(
      width: double.infinity,
      color: theme.colorScheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(
            Icons.cloud_off_rounded,
            size: 16,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              at == null
                  ? '当前离线，显示的是本地缓存'
                  : '当前离线，显示的是上次同步的内容（${_formatTime(at)}）',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.onSecondaryContainer,
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('重试'),
            ),
        ],
      ),
    );
  }

  /// 相对时间。超过一天用日期，更早不用显示——那种缓存多半已经没参考价值了。
  static String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';

    final month = time.month.toString().padLeft(2, '0');
    final day = time.day.toString().padLeft(2, '0');
    return '${time.year}-$month-$day';
  }
}
