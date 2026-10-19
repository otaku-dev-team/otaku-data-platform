import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';
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
    final theme = Theme.of(context);
    final tags = work.tags;

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          work.title,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
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
          ],
        ),
        if (tags != null) ...[
          const SizedBox(height: 12),
          TagChips(tags: tags, maxVisible: 8),
        ],
        const SizedBox(height: 24),
        _SummaryBlock(text: work.summary),
        const SizedBox(height: 28),
        _SourceLine(work: work),
      ],
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppLayout.pagePadding),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < AppLayout.twoColumnBreakpoint) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: CoverImage(
                    url: work.coverUrl,
                    width: 160,
                    height: 218,
                    radius: 12,
                  ),
                ),
                const SizedBox(height: 20),
                info,
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CoverImage(
                url: work.coverUrl,
                width: AppLayout.detailCoverWidth,
                height: AppLayout.detailCoverHeight,
                radius: 12,
              ),
              const SizedBox(width: 28),
              Expanded(child: info),
            ],
          );
        },
      ),
    );
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

/// 溯源信息。契约 3.1：`source_id` 可以展示，但不得用于业务判断。
class _SourceLine extends StatelessWidget {
  const _SourceLine({required this.work});

  final Work work;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = <String>[
      if (work.source.isNotEmpty) '来源 ${work.source}',
      if (work.sourceId.isNotEmpty) '来源 ID ${work.sourceId}',
      if (work.updatedAt != null) '更新于 ${_formatDate(work.updatedAt!)}',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();

    return Text(
      parts.join(' · '),
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
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
