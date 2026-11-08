import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../core/theme/design_tokens.dart';
import '../config/feature_flags.dart';
import 'ugc_review.dart';

/// 作品详情页的「我的点评」区块：概览 + 打分 / 写评 + 编辑 / 删除。
///
/// 三条与契约对齐的规则：
///
/// 1. **评分与正文至少一项**（两项都空服务端 `400`），所以提交前先拦；
/// 2. **一人一条**：已点评时显示编辑，而不是再发一条。万一服务端返回
///    `409 REVIEW_EXISTS`（公开列表里没找到我那条，见 #531），如实提示；
/// 3. `pending`（先审后发）照常显示，但要标「审核中」——否则用户以为发失败了。
class WorkReviewSection extends ConsumerStatefulWidget {
  const WorkReviewSection({super.key, required this.workId});

  final String workId;

  @override
  ConsumerState<WorkReviewSection> createState() => _WorkReviewSectionState();
}

class _WorkReviewSectionState extends ConsumerState<WorkReviewSection> {
  final TextEditingController _body = TextEditingController();

  /// 0 = 还没选分数。
  int _rating = 0;
  bool _editing = false;
  bool _busy = false;

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  Future<void> _submit(WorkReview? existing) async {
    if (_busy) return;
    // 服务端开关（`feature.work_review`，默认关）。关着时不写任何数据。
    if (!ref.read(featureFlagsProvider).workReview) {
      _toast('点评功能暂未开放');
      return;
    }
    final body = _body.text.trim();
    if (_rating <= 0 && body.isEmpty) {
      _toast('至少打个分或写一句');
      return;
    }
    setState(() => _busy = true);
    final source = ref.read(ugcReviewDataSourceProvider);
    try {
      if (existing == null) {
        await source.create(
          workId: widget.workId,
          rating: _rating <= 0 ? null : _rating,
          body: body.isEmpty ? null : body,
        );
      } else {
        await source.update(
          existing.reviewId,
          // 契约：省略 = 沿用、`null` = 清空。这里保存整份表单，
          // 用户清空正文就是真的清空。
          rating: _rating <= 0 ? null : _rating,
          body: body.isEmpty ? null : body,
        );
      }
      _refresh();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _editing = false;
      });
      _toast(existing == null ? '点评已发表' : '点评已更新');
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast(error.userMessage);
    } on Object {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('提交失败，请稍后重试');
    }
  }

  Future<void> _delete(WorkReview review) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(ugcReviewDataSourceProvider).delete(review.reviewId);
      _refresh();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _editing = false;
        _rating = 0;
        _body.clear();
      });
      _toast('点评已删除');
    } on Object {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('删除失败，请稍后重试');
    }
  }

  void _refresh() {
    ref.invalidate(myWorkReviewProvider(widget.workId));
    // 概览也变了：条数与均分都受影响。
    ref.invalidate(workReviewSummaryProvider(widget.workId));
  }

  void _toast(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _startEdit(WorkReview review) {
    setState(() {
      _editing = true;
      _rating = review.rating ?? 0;
      _body.text = review.body ?? '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final summary = ref.watch(workReviewSummaryProvider(widget.workId)).value;
    final signedIn = ref.watch(ugcReviewAudienceProvider);
    final mine = ref.watch(myWorkReviewProvider(widget.workId)).value;
    final reviewEnabled = ref.watch(featureFlagsProvider).workReview;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(Space.s4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 大字号下「8.0 分 · 3 条点评」会把这一行撑爆（320 宽 + 2 倍字号
            // 实测溢出 53px）。`Wrap` 在窄屏换行、宽屏两端对齐，不依赖 flex。
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: Space.s2,
              runSpacing: Space.s1,
              children: [
                Text('我的点评', style: theme.textTheme.titleSmall),
                if (summary != null && !summary.isEmpty)
                  Text(
                    summary.average == null
                        ? '${summary.total} 条点评'
                        : '${summary.average!.toStringAsFixed(1)} 分 · ${summary.total} 条点评',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: Space.s3),
            if (!reviewEnabled) ...[
              // 开关关着（`feature.work_review` 默认 false）：**不展示编辑器**，
              // 但**保留概览**——那是只读数据，藏起来反而少一层信息。
              // 若之前在 1.1.7 里发过，仍给「删除」让用户清理自己的数据。
              if (mine != null && !mine.isDeleted)
                _MineView(
                  review: mine,
                  busy: _busy,
                  canEdit: false,
                  onEdit: () {},
                  onDelete: () => _delete(mine),
                )
              else
                Text(
                  '点评功能暂未开放。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ] else if (!signedIn)
              Text(
                '登录后可以打分、写点评。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else if (mine != null && !_editing)
              _MineView(
                review: mine,
                busy: _busy,
                canEdit: true,
                onEdit: () => _startEdit(mine),
                onDelete: () => _delete(mine),
              )
            else
              _Editor(
                rating: _rating,
                controller: _body,
                busy: _busy,
                isEditing: _editing,
                onRating: (value) => setState(() => _rating = value),
                onSubmit: () => _submit(_editing ? mine : null),
                onCancel: mine == null
                    ? null
                    : () => setState(() {
                        _editing = false;
                        _rating = mine.rating ?? 0;
                        _body.text = mine.body ?? '';
                      }),
              ),
          ],
        ),
      ),
    );
  }
}

class _MineView extends StatelessWidget {
  const _MineView({
    required this.review,
    required this.busy,
    required this.canEdit,
    required this.onEdit,
    required this.onDelete,
  });

  final WorkReview review;
  final bool busy;

  /// 服务端开关关着时为 `false`：不给「编辑」（改了也不会公开，只会白写一遍）。
  final bool canEdit;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 「已删除 / 已被隐藏」不展示分数与正文：它们不再是有效点评，
    // 但仍占着「一人一条」的位置，所以要给个说明和清理入口。
    final inactive = review.isDeleted || review.isHidden;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: Space.s2,
          runSpacing: Space.s1,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (inactive)
                  Text(
                    review.isDeleted ? '这条点评已删除' : '这条点评已被隐藏',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  )
                else if (review.rating != null)
                  Text(
                    '${review.rating} 分',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                if (review.isPending) ...[
                  const SizedBox(width: Space.s2),
                  Text(
                    '审核中',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (review.isEditable && canEdit)
                  TextButton(
                    onPressed: busy ? null : onEdit,
                    child: const Text('编辑'),
                  ),
                TextButton(
                  onPressed: busy ? null : onDelete,
                  child: const Text('删除'),
                ),
              ],
            ),
          ],
        ),
        if (!inactive && review.body != null) ...[
          const SizedBox(height: Space.s1),
          Text(review.body!, style: theme.textTheme.bodyMedium),
        ],
      ],
    );
  }
}

class _Editor extends StatelessWidget {
  const _Editor({
    required this.rating,
    required this.controller,
    required this.busy,
    required this.isEditing,
    required this.onRating,
    required this.onSubmit,
    required this.onCancel,
  });

  final int rating;
  final TextEditingController controller;
  final bool busy;
  final bool isEditing;
  final ValueChanged<int> onRating;
  final VoidCallback onSubmit;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: Space.s2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '评分',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              rating <= 0 ? '未选（可以只写文字）' : '$rating 分',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        Slider(
          value: rating <= 0 ? 0 : rating.toDouble(),
          max: 10,
          divisions: 10,
          label: rating <= 0 ? '未选' : '$rating',
          onChanged: busy ? null : (value) => onRating(value.round()),
        ),
        TextField(
          controller: controller,
          maxLines: 3,
          maxLength: 5000,
          enabled: !busy,
          decoration: const InputDecoration(
            hintText: '写点什么，或者只打个分（可选）',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        Row(
          children: [
            if (onCancel != null)
              TextButton(
                onPressed: busy ? null : onCancel,
                child: const Text('取消'),
              ),
            const Spacer(),
            FilledButton.tonal(
              onPressed: busy ? null : onSubmit,
              child: busy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(isEditing ? '保存' : '发表'),
            ),
          ],
        ),
      ],
    );
  }
}
