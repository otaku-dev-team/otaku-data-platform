import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/recent_view.dart';
import '../../shared/widgets/empty_state.dart';
import '../contents/work_list_tile.dart';
import 'recent_views_controller.dart';

/// 最近浏览的完整列表（二级页）。
///
/// 首页那条横排只放得下最近几部，想回头找更早看过的没有入口。这一页补上：
/// 按「今天 / 昨天 / 更早」分组，支持滑动删单条、右上角整体清空。
///
/// 三个刻意的取舍：
///
/// 1. **分组而不是页码分页**。上限 50 条，按「今天 / 昨天 / 更早」切三段比
///    翻页更符合"我在找前阵子看的那个"的直觉；页码分页是桌面习惯。
/// 2. **不做搜索**。50 条、三段分组、每行带标题，滑两下就到头了；
///    搜索结果页要另配一套匹配与高亮规则，收益不如把条数上限压住。
/// 3. **删除给撤销**。滑动很容易误触，而历史删了就真没了（不像收藏能重新拉），
///    所以删完的 SnackBar 里必须有「撤销」，且放回原位置而不是置顶。
class RecentHistoryPage extends ConsumerWidget {
  const RecentHistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(recentViewsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('最近浏览'),
        actions: [
          if (items.isNotEmpty)
            IconButton(
              tooltip: '清空',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () => _confirmClear(context, ref),
            ),
        ],
      ),
      body: items.isEmpty
          ? const EmptyState(
              icon: Icons.history_toggle_off_rounded,
              title: '还没有浏览记录',
              message: '打开任意作品详情后，这里会留下足迹。记录只存在这台设备上。',
            )
          : _GroupedList(items: items),
    );
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空最近浏览？'),
        content: const Text('只清空这台设备上的浏览记录，不影响收藏与离线缓存。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    ref.read(recentViewsProvider.notifier).clear();
  }
}

/// 按「今天 / 昨天 / 更早」切三段。
///
/// 分组边界用**本地日期**算，不是「24 小时前」：凌晨一点打开时，
/// 昨晚十点看的应该落在「昨天」里，而不是「今天」。
class _GroupedList extends ConsumerWidget {
  const _GroupedList({required this.items});

  final List<RecentView> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    final todayItems = <RecentView>[];
    final yesterdayItems = <RecentView>[];
    final earlierItems = <RecentView>[];
    for (final item in items) {
      final at = item.viewedAt;
      final day = DateTime(at.year, at.month, at.day);
      if (!day.isBefore(today)) {
        todayItems.add(item);
      } else if (!day.isBefore(yesterday)) {
        yesterdayItems.add(item);
      } else {
        earlierItems.add(item);
      }
    }

    // 每段内部的序号用于撤销时放回原位：全局下标，不是段内下标。
    int indexOf(RecentView item) => items.indexOf(item);

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        ..._section(context, ref, '今天', todayItems, indexOf),
        ..._section(context, ref, '昨天', yesterdayItems, indexOf),
        ..._section(context, ref, '更早', earlierItems, indexOf),
      ],
    );
  }

  List<Widget> _section(
    BuildContext context,
    WidgetRef ref,
    String title,
    List<RecentView> sectionItems,
    int Function(RecentView) indexOf,
  ) {
    if (sectionItems.isEmpty) return const [];

    final theme = Theme.of(context);
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Row(
          children: [
            Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${sectionItems.length}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
      for (final item in sectionItems)
        _DismissibleTile(item: item, index: indexOf(item)),
    ];
  }
}

class _DismissibleTile extends ConsumerWidget {
  const _DismissibleTile({required this.item, required this.index});

  final RecentView item;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Dismissible(
      key: ValueKey(item.workId),
      // 只允许从右往左滑：从左往右在 Android 上与返回手势冲突。
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: theme.colorScheme.errorContainer,
        child: Icon(
          Icons.delete_outline_rounded,
          color: theme.colorScheme.onErrorContainer,
        ),
      ),
      onDismissed: (_) {
        ref.read(recentViewsProvider.notifier).remove(item.workId);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('已删除「${item.work.title}」'),
              action: SnackBarAction(
                label: '撤销',
                onPressed: () => ref
                    .read(recentViewsProvider.notifier)
                    .restore(item, index),
              ),
            ),
          );
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: WorkListTile(work: item.work),
      ),
    );
  }
}
