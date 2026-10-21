import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/collection_entry.dart';
import '../../data/models/work.dart';
import '../../shared/widgets/collection_status_menu.dart';
import '../../shared/widgets/cover_image.dart';
import '../../shared/widgets/desktop_shortcuts.dart';
import '../../shared/widgets/error_state.dart';
import '../../shared/widgets/rating_badge.dart';
import '../../shared/widgets/release_year_text.dart';
import '../../shared/widgets/skeleton_list.dart';
import '../../shared/widgets/tag_chips.dart';
import '../../shared/widgets/work_type_tag.dart';
import '../auth/auth_controller.dart';
import 'work_collection_controller.dart';
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

    return DesktopShortcuts(
      child: Scaffold(
        appBar: AppBar(title: const Text('作品详情')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: AppLayout.detailMaxWidth,
            ),
            child: _buildBody(context, ref, work),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<Work> work,
  ) {
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
            ReleaseYearText(year: work.releaseYear),
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
        const SizedBox(height: 16),
        _CollectBar(work: work),
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

/// 收藏区：收藏按钮 + 观看状态。
///
/// 这是详情页唯一的写入口，四种形态各有明确出口，不留「点了没反应」的按钮：
/// - 未登录 → 「登录后收藏」，登录成功回到这里**直接把这部作品收进去**
///   （用户的意图就是收藏，不该登录完再点一次）；
/// - 状态未就绪 → 与按钮同高的占位，不跳动；
/// - 查询失败 → 说明失败 + 重试，不假装「没收藏」（C7）；
/// - 已收藏 → 按钮变「已收藏」，旁边出现状态选择器。
class _CollectBar extends ConsumerStatefulWidget {
  const _CollectBar({required this.work});

  final Work work;

  @override
  ConsumerState<_CollectBar> createState() => _CollectBarState();
}

class _CollectBarState extends ConsumerState<_CollectBar> {
  bool _busy = false;

  Future<void> _run(
    Future<ApiException?> Function() action, {
    String? successMessage,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    final error = await action();
    if (!mounted) return;
    setState(() => _busy = false);

    final message = error?.userMessage ?? successMessage;
    if (message == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _toggle({required bool collected}) {
    return _run(
      () => ref
          .read(workCollectionProvider(widget.work.workId).notifier)
          .toggle(widget.work),
      successMessage: collected ? '已取消收藏' : '已加入收藏',
    );
  }

  Future<void> _signInThenCollect() async {
    await context.push(RoutePaths.login);
    if (!mounted) return;
    // 用户按「先不登录」回来时什么都不做，界面这时已经变回可点的「收藏」。
    if (!ref.read(authControllerProvider).isSignedIn) return;

    await _run(
      () => ref
          .read(workCollectionProvider(widget.work.workId).notifier)
          .collect(widget.work),
      successMessage: '已加入收藏',
    );
  }

  Future<void> _setStatus(CollectionStatus? status) {
    return _run(
      () => ref
          .read(workCollectionProvider(widget.work.workId).notifier)
          .setStatus(status),
      successMessage: status == null ? '已清除观看状态' : '已标记为「${status.label}」',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 未登录时也订阅：那时 build 直接返回「未收藏」、不发请求，
    // 订阅是为了登录回来后这块状态自己就位，不用等用户再点一次。
    final remote = ref.watch(workCollectionProvider(widget.work.workId));
    final auth = ref.watch(authControllerProvider);

    if (auth.status == AuthStatus.checking) return const _CollectPlaceholder();

    if (!auth.isSignedIn) {
      return Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            onPressed: _signInThenCollect,
            icon: const Icon(Icons.bookmark_add_outlined, size: 18),
            label: const Text('登录后收藏'),
          ),
          Text(
            '收藏会同步到手机和桌面',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    final collection = remote.value;

    if (collection == null) {
      if (!remote.hasError) return const _CollectPlaceholder();
      // 状态查不到时不能显示成「未收藏」：那会诱导用户再收一次。
      return Row(
        children: [
          Icon(
            Icons.cloud_off_rounded,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '收藏状态获取失败',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton(
            onPressed: () =>
                ref.invalidate(workCollectionProvider(widget.work.workId)),
            child: const Text('重试'),
          ),
        ],
      );
    }

    final collected = collection.collected;
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Tooltip(
          message: collected ? '取消收藏' : '加入收藏',
          child: FilledButton.tonalIcon(
            onPressed: _busy ? null : () => _toggle(collected: collected),
            icon: Icon(
              collected
                  ? Icons.bookmark_added_rounded
                  : Icons.bookmark_add_outlined,
              size: 18,
            ),
            label: Text(collected ? '已收藏' : '收藏'),
          ),
        ),
        if (collected)
          CollectionStatusMenu(
            status: collection.status,
            enabled: !_busy,
            onSelected: _setStatus,
          ),
      ],
    );
  }
}

/// 与收藏按钮同高的占位：状态未就绪时先占住位置，
/// 避免按钮出现时把下面的标签区推下去。
class _CollectPlaceholder extends StatelessWidget {
  const _CollectPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 40,
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
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
      if (work.releaseYear != null)
        (label: '年份', value: '${work.releaseYear}'),
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
              overflow: _expanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
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
