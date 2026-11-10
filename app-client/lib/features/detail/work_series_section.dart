import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/route_paths.dart';
import '../../core/theme/design_tokens.dart';
import '../../data/models/work_series.dart';
import '../../shared/widgets/cover_image.dart';
import '../series/series_data_source.dart';

/// 详情页「系列作品」区（`GET /api/works/{work_id}/series`，#411 / #557 / #568 P2）。
///
/// 与「相关作品」分开请求、分开缓存：系列拿不到时详情页照常显示，
/// 不能因为一个装饰性区块把作品本身拖进错误态。
final workSeriesProvider = FutureProvider.family<WorkSeries, String>((
  ref,
  workId,
) {
  return ref.watch(seriesDataSourceProvider).fetchForWork(workId);
}, retry: (retryCount, error) => null);

/// 三条边界决定这个区块的形状：
/// - **没有系列**（绝大多数作品）→ 200 + 空 items，**整块不渲染**，不写「暂无系列」；
/// - **请求失败 / 404** → 同样整块不渲染。系列是锦上添花，不是作品信息的必要部分；
/// - **`series_name` 为 null**（作品先到、系列行后到）→ 标题退化成「系列作品」，
///   **绝不拿 `series_key` 顶替**：那是来源站内部 id。
///
/// 顺序照服务端（档位 → 年代升序），端上**不重排**：那是观看顺序语义，
/// 按评分重排会把特别篇顶到第一季前面。
class WorkSeriesSection extends ConsumerWidget {
  const WorkSeriesSection({super.key, required this.workId});

  final String workId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(workSeriesProvider(workId));

    // 不摆骨架：20 万部作品里只有 2 千多部有系列，给 99% 的用户留一块
    // 「先空白、再突然出现」的占位，比直接不显示更糟。
    final data = async.value;
    if (async.isLoading || async.hasError || data == null || data.isEmpty) {
      return const SizedBox.shrink();
    }

    final name = data.seriesName;
    final key = data.seriesKey;
    final canOpenPage = name != null && key != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: canOpenPage
                  ? InkWell(
                      onTap: () => context.push(RoutePaths.seriesPage(key)),
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                name,
                                style: theme.textTheme.titleMedium,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.chevron_right_rounded,
                              size: 18,
                              color: theme.colorScheme.primary,
                            ),
                          ],
                        ),
                      ),
                    )
                  : Text(
                      '系列作品',
                      style: theme.textTheme.titleMedium,
                    ),
            ),
          ],
        ),
        const SizedBox(height: Space.s2),
        for (final item in data.items)
          _SeriesRow(item: item, isCurrent: item.work.workId == workId),
        const SizedBox(height: Space.s3),
      ],
    );
  }
}

class _SeriesRow extends StatelessWidget {
  const _SeriesRow({required this.item, required this.isCurrent});

  final WorkSeriesItem item;

  /// `items` 包含当前作品，服务端不替客户端剔除——自己标记、不可点。
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final work = item.work;
    final firstChar = work.title.characters.isEmpty
        ? null
        : work.title.characters.first;
    final muted = theme.colorScheme.onSurfaceVariant;

    return InkWell(
      // 当前项不可点：点进去还是这一页，只会白转一圈。
      onTap: isCurrent
          ? null
          : () => context.push(RoutePaths.workDetail(work.workId)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.s2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CoverImage(
              url: work.coverUrl,
              width: 40,
              height: 60,
              radius: 6,
              placeholderLabel: firstChar,
              source: work.source,
            ),
            const SizedBox(width: Space.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    work.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: isCurrent ? muted : null,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // 不用 Wrap：这里在正文纵向滚动流里，行内三个短标签用 Row 足够，
                  // Wrap 放进固定高度容器会静默画到容器外（#455 踩过）。
                  Row(
                    children: [
                      _Chip(label: item.relation.label),
                      if (isCurrent) ...[
                        const SizedBox(width: 6),
                        _Chip(label: '当前在看', highlighted: true),
                      ],
                      if (work.releaseYear != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          '${work.releaseYear}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: muted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, this.highlighted = false});

  final String label;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: highlighted
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: highlighted
              ? scheme.onPrimaryContainer
              : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
