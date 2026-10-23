import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';
import '../../data/models/schedule.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/error_state.dart';
import '../../shared/widgets/tag_chips.dart';
import 'schedule_controller.dart';

/// 每日新番档期页。
///
/// 数据来自 `GET /api/schedule`（后端按星期分组一次返回）。
/// 交互：顶部 chips 选天（默认「全部」），AppBar 切换季度；
/// 条目命中本地作品才可点（跳详情），未命中只展示——不给死链。
class SchedulePage extends ConsumerWidget {
  const SchedulePage({super.key});

  /// 顶部 chips 的顺序：全部 + 周一…周日 + 待定。
  static const List<ScheduleWeekday> _chips = [
    ScheduleWeekday.all,
    ScheduleWeekday.monday,
    ScheduleWeekday.tuesday,
    ScheduleWeekday.wednesday,
    ScheduleWeekday.thursday,
    ScheduleWeekday.friday,
    ScheduleWeekday.saturday,
    ScheduleWeekday.sunday,
    ScheduleWeekday.undecided,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final schedule = ref.watch(scheduleProvider);
    final selected = ref.watch(scheduleWeekdayProvider);
    final group = ref.watch(visibleScheduleProvider);
    final data = schedule.value;

    return Scaffold(
      appBar: AppBar(
        title: const Text('每日新番'),
        actions: [
          // 季度切换。只有真的拿到多个季度才显示，否则一个孤零零的
          // 下拉箭头会让人以为还有别的季度可看。
          if (data != null && data.seasons.length > 1)
            PopupMenuButton<String>(
              tooltip: '切换季度',
              icon: const Icon(Icons.calendar_month_outlined),
              initialValue: data.season,
              onSelected: (season) =>
                  ref.read(scheduleSeasonProvider.notifier).select(season),
              itemBuilder: (context) => [
                for (final season in data.seasons)
                  PopupMenuItem<String>(
                    value: season,
                    child: Text(_seasonLabel(season)),
                  ),
              ],
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _buildBody(context, ref, schedule, selected, group),
    );
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<SchedulePageData> schedule,
    ScheduleWeekday selected,
    ScheduleGroup? group,
  ) {
    if (schedule.isLoading && !schedule.hasValue) {
      return const Center(child: CircularProgressIndicator());
    }

    if (schedule.hasError) {
      return ErrorState(
        error: ApiException.fromAny(schedule.error),
        onRetry: () => ref.invalidate(scheduleProvider),
      );
    }

    final data = schedule.value;
    if (data == null) {
      return const SizedBox.shrink();
    }

    if (data.isEmpty) {
      return RefreshIndicator(
        onRefresh: () async => ref.invalidate(scheduleProvider),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 72),
            EmptyState(
              icon: Icons.event_busy_outlined,
              title: '还没有档期数据',
              message: '等同步任务跑完就有了，也可以下拉刷新试试',
            ),
          ],
        ),
      );
    }

    final items = group?.items ?? const [];
    return Column(
      children: [
        _WeekdayChips(
          selected: selected,
          onSelected: (weekday) =>
              ref.read(scheduleWeekdayProvider.notifier).select(weekday),
        ),        if (data.season case final season?)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppLayout.pagePadding,
              4,
              AppLayout.pagePadding,
              8,
            ),
            child: Row(
              children: [
                Text(
                  _seasonLabel(season),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                Text(
                  '${items.length} 部',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: items.isEmpty
              ? _buildEmptyDay(context, ref)
              : RefreshIndicator(
                  onRefresh: () async => ref.invalidate(scheduleProvider),
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(
                      AppLayout.pagePadding,
                      0,
                      AppLayout.pagePadding,
                      24,
                    ),
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) =>
                        _ScheduleTile(entry: items[index]),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildEmptyDay(BuildContext context, WidgetRef ref) {
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(scheduleProvider),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 72),
          EmptyState(
            icon: Icons.tv_off_outlined,
            title: '这天没有新番',
            message: '换一天看看，或者切到「全部」',
          ),
        ],
      ),
    );
  }

  /// 季度编码 202610 → 「2026 年 10 月」。解析不了的原文返回。
  static String _seasonLabel(String season) {
    if (season.length == 6 && int.tryParse(season) != null) {
      return '${season.substring(0, 4)} 年 ${int.parse(season.substring(4, 6))} 月';
    }
    return season;
  }
}

class _WeekdayChips extends StatelessWidget {
  const _WeekdayChips({required this.selected, required this.onSelected});

  final ScheduleWeekday selected;
  final ValueChanged<ScheduleWeekday> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(
        AppLayout.pagePadding,
        8,
        AppLayout.pagePadding,
        8,
      ),
      child: Row(
        children: [
          for (final weekday in SchedulePage._chips)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(weekday.label),
                selected: selected == weekday,
                onSelected: (_) => onSelected(weekday),
              ),
            ),
        ],
      ),
    );
  }
}

class _ScheduleTile extends StatelessWidget {
  const _ScheduleTile({required this.entry});

  final ScheduleEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final firstChar = entry.title.characters.isEmpty
        ? null
        : entry.title.characters.first;
    final scheduleTime = entry.broadcastTime ?? entry.broadcastNote;

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppLayout.cardRadius),
        // 未命中本地作品：整卡不可点，并在副标题说明原因。
        onTap: entry.isLinked
            ? () => context.push(RoutePaths.workDetail(entry.workId!))
            : null,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 封面是 B 站外链，加载失败走占位图；mock 与真实同一条路径。
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: AppLayout.coverWidth,
                  height: AppLayout.coverHeight,
                  child: entry.imageUrl != null
                      ? Image.network(
                          entry.imageUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => _CoverPlaceholder(
                            label: firstChar,
                          ),
                        )
                      : _CoverPlaceholder(label: firstChar),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (scheduleTime != null)
                      Text(
                        scheduleTime,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    if (entry.workType != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        entry.workType!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (entry.tags != null && entry.tags!.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      TagChips(tags: entry.tags, maxVisible: 3),
                    ],
                    if (!entry.isLinked) ...[
                      const SizedBox(height: 6),
                      Text(
                        '本站未收录，仅展示档期信息',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder({this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Text(
        label ?? '?',
        style: theme.textTheme.titleLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
