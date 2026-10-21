import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/work.dart';
import '../../shared/widgets/cover_image.dart';
import '../../shared/widgets/error_state.dart';
import '../../shared/widgets/rating_badge.dart';
import '../../shared/widgets/skeleton_list.dart';
import '../../shared/widgets/tag_chips.dart';
import '../../shared/widgets/work_type_tag.dart';
import 'work_detail_controller.dart';

/// 作品详情。契约 6.2 / 6.3：
/// - 404 → 提示 + 返回列表，**不自动重试**；
/// - `summary` 为 null → "暂无简介"，超长时折叠；
/// - `main_rating`、`tags` 为空 → 对应区块不渲染。
///
/// 版面按站点的详情页顺序摆：封面 + 标题 + 分类评分 → 简介 → 收录信息。
/// 站点还有原名、别名、年份、话数、制作、导演、声优、系列、相关推荐，
/// 这些字段平台契约里都还没有，**这里不摆空位**——空占位比少显示更误导。
class WorkDetailPage extends ConsumerWidget {
  const WorkDetailPage({super.key, required this.workId});

  final String workId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final work = ref.watch(workDetailProvider(workId));

    return Scaffold(
      appBar: AppBar(title: const Text('作品详情')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppLayout.detailMaxWidth),
          child: _buildBody(context, ref, work),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, WidgetRef ref, AsyncValue<Work> work) {
    if (work.isLoading && !work.hasValue) {
      return const SkeletonDetail();
    }

    if (work.hasError) {
      final error = ApiException.fromAny(work.error);
      if (error.isNotFound) {
        return ErrorState(
          error: error,
          title: '作品不存在',
          action: OutlinedButton(
            onPressed: () => _backToList(context),
            child: const Text('返回列表'),
          ),
        );
      }
      return ErrorState(
        error: error,
        onRetry: () => ref.invalidate(workDetailProvider(workId)),
      );
    }

    return _DetailBody(work: work.requireValue);
  }

  void _backToList(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(RoutePaths.contents);
    }
  }
}

class _DetailBody extends StatelessWidget {
  const _DetailBody({required this.work});

  final Work work;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppLayout.pagePadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final cover = CoverImage(
                url: work.coverUrl,
                width: AppLayout.detailCoverWidth,
                height: AppLayout.detailCoverHeight,
                radius: 14,
              );

              if (constraints.maxWidth < AppLayout.twoColumnBreakpoint) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(child: cover),
                    const SizedBox(height: 20),
                    _Headline(work: work),
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  cover,
                  const SizedBox(width: 28),
                  Expanded(child: _Headline(work: work)),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
          _RecordPanel(work: work),
        ],
      ),
    );
  }
}

/// 标题区：标题 / 类型 / 评分 / 标签 / 简介。
class _Headline extends StatelessWidget {
  const _Headline({required this.work});

  final Work work;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tags = work.tags;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          work.title,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            height: 1.25,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            WorkTypeTag(type: work.workType),
            RatingBadge(rating: work.mainRating),
            if (work.mainRating != null)
              Text(
                // 契约里的尺度是 `0-10`，站点写的是「满分 10 分」——取上界即可。
                '满分 ${work.mainRating!.scale.split('-').last} 分',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        if (tags != null) ...[
          const SizedBox(height: 12),
          TagChips(tags: tags, maxVisible: 10),
        ],
        const SizedBox(height: 20),
        const Divider(height: 1),
        const SizedBox(height: 16),
        Text(
          '简介',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        _SummaryBlock(text: work.summary),
      ],
    );
  }
}

/// 收录信息。站点这一块放的是原名 / 话数 / 制作 / 放送 / 声优，
/// 平台目前只有溯源类字段，所以只摆**确实有值**的行，缺失的整行不出现。
class _RecordPanel extends StatelessWidget {
  const _RecordPanel({required this.work});

  final Work work;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <({String label, String value})>[
      (label: '作品 ID', value: work.workId),
      if (work.source.isNotEmpty) (label: '来源', value: work.source),
      if (work.sourceId.isNotEmpty) (label: '来源 ID', value: work.sourceId),
      if (work.updatedAt != null)
        (label: '收录更新', value: _formatDate(work.updatedAt!)),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: AppTheme.cardColor(context),
        borderRadius: BorderRadius.circular(AppLayout.cardRadius),
        border: Border.all(color: AppTheme.borderColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '收录信息',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          // 站点资料区是「左标签右值」的两列排布，这里沿用同一套读法。
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 88,
                    child: Text(
                      row.label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(
                    child: SelectableText(
                      row.value,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 10),
          Text(
            '资料整理自 ${work.source.isEmpty ? '来源站点' : work.source}，仅作展示与学习用途。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  static String _formatDate(DateTime value) {
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day';
  }
}

/// 简介。`null` → "暂无简介"；超长 → 折叠 8 行，可展开。
class _SummaryBlock extends StatefulWidget {
  const _SummaryBlock({required this.text});

  final String? text;

  @override
  State<_SummaryBlock> createState() => _SummaryBlockState();
}

class _SummaryBlockState extends State<_SummaryBlock> {
  static const int _collapsedLines = 8;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = widget.text;

    if (text == null || text.isEmpty) {
      return Text(
        '暂无简介',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    final style = theme.textTheme.bodyMedium?.copyWith(height: 1.75);

    return LayoutBuilder(
      builder: (context, constraints) {
        // 先量一遍：撑不满 8 行就不显示"展开"，避免短简介下面挂个没用的按钮。
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: _collapsedLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final canExpand = painter.didExceedMaxLines;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              text,
              style: style,
              maxLines: _expanded ? null : _collapsedLines,
              overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
            ),
            if (canExpand)
              TextButton.icon(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => setState(() => _expanded = !_expanded),
                icon: Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                ),
                label: Text(_expanded ? '收起' : '展开全文'),
              ),
          ],
        );
      },
    );
  }
}
