import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';
import '../../data/models/collection_entry.dart';
import '../../shared/widgets/cover_image.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/error_state.dart';
import '../../shared/widgets/skeleton_list.dart';
import '../../shared/widgets/work_type_tag.dart';
import '../auth/auth_controller.dart';
import 'collection_controller.dart';

/// 我的收藏。跨端同步的落点：所有数据以服务端返回为准，本地不做乐观推断。
///
/// 页面有四种形态，验收时逐条对：
/// - 未登录 → 登录引导（不是空列表，也不能显示别人的数据）
/// - 加载中 → 骨架屏
/// - 查询失败 → 错误态 + 重试
/// - 空 / 有数据 → 空状态 / 列表
class CollectionPage extends ConsumerWidget {
  const CollectionPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的收藏'),
        actions: [
          if (auth.isSignedIn) ...[
            IconButton(
              tooltip: '刷新',
              onPressed: () =>
                  ref.read(collectionControllerProvider.notifier).refresh(),
              icon: const Icon(Icons.refresh),
            ),
            _AccountMenu(userLabel: auth.user!.label),
          ] else if (auth.status == AuthStatus.checking)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            TextButton(
              onPressed: () => context.push(RoutePaths.login),
              child: const Text('登录'),
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppLayout.listMaxWidth),
          child: switch (auth.status) {
            AuthStatus.checking => const SkeletonList(),
            AuthStatus.signedOut => const _SignInPrompt(),
            AuthStatus.signedIn => const _CollectionBody(),
          },
        ),
      ),
    );
  }
}

class _AccountMenu extends ConsumerWidget {
  const _AccountMenu({required this.userLabel});

  final String userLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return PopupMenuButton<String>(
      tooltip: '账号',
      icon: const Icon(Icons.account_circle_outlined),
      onSelected: (value) {
        if (value == 'logout') {
          // 只结束当前会话：桌面端不受影响（C9）。
          ref.read(authControllerProvider.notifier).logout();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          enabled: false,
          child: Text(
            userLabel,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(value: 'logout', child: Text('退出登录')),
      ],
    );
  }
}

class _SignInPrompt extends StatelessWidget {
  const _SignInPrompt();

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.lock_outline_rounded,
      title: '登录后可以跨端同步收藏',
      message: '手机和桌面用同一个账号，收藏与观看状态会自动对齐。',
      action: FilledButton(
        onPressed: () => context.push(RoutePaths.login),
        child: const Text('去登录'),
      ),
    );
  }
}

class _CollectionBody extends ConsumerWidget {
  const _CollectionBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(collectionFilterProvider);
    final collections = ref.watch(collectionControllerProvider);

    return Column(
      children: [
        _StatusFilters(
          selected: filter,
          onSelected: (status) =>
              ref.read(collectionFilterProvider.notifier).select(status),
        ),
        Expanded(
          child: _buildList(context, ref, collections, filter),
        ),
      ],
    );
  }

  Widget _buildList(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<CollectionEntry>> collections,
    CollectionStatus? filter,
  ) {
    final items = collections.value;
    if (collections.isLoading && items == null) return const SkeletonList();

    if (collections.hasError && items == null) {
      return ErrorState(
        error: ApiException.fromAny(collections.error),
        onRetry: () => ref.read(collectionControllerProvider.notifier).refresh(),
      );
    }

    final data = items ?? const <CollectionEntry>[];
    if (data.isEmpty) {
      return EmptyState(
        icon: Icons.bookmark_border_rounded,
        title: filter == null ? '还没有收藏' : '没有「${filter.label}」的作品',
        message: filter == null ? '在作品详情页点收藏，就会出现在这里。' : '换个状态看看。',
      );
    }

    return RefreshIndicator(
      onRefresh: () =>
          ref.read(collectionControllerProvider.notifier).refresh(),
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(
          AppLayout.pagePadding,
          4,
          AppLayout.pagePadding,
          24,
        ),
        itemCount: data.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) => _CollectionTile(entry: data[index]),
      ),
    );
  }
}

class _StatusFilters extends StatelessWidget {
  const _StatusFilters({required this.selected, required this.onSelected});

  final CollectionStatus? selected;
  final ValueChanged<CollectionStatus?> onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppLayout.pagePadding,
        8,
        AppLayout.pagePadding,
        4,
      ),
      child: Wrap(
        spacing: 8,
        children: [
          ChoiceChip(
            label: const Text('全部'),
            selected: selected == null,
            onSelected: (_) => onSelected(null),
          ),
          for (final status in CollectionStatus.values)
            ChoiceChip(
              label: Text(status.label),
              selected: selected == status,
              onSelected: (_) => onSelected(status),
            ),
        ],
      ),
    );
  }
}

class _CollectionTile extends ConsumerWidget {
  const _CollectionTile({required this.entry});

  final CollectionEntry entry;

  Future<void> _changeStatus(
    BuildContext context,
    WidgetRef ref,
    CollectionStatus? status,
  ) async {
    final error = await ref
        .read(collectionControllerProvider.notifier)
        .changeStatus(entry.workId, status);
    if (!context.mounted || error == null) return;
    // 失败必须说出来（C7）：不静默、不把界面留在「好像成功了」。
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error.userMessage)),
    );
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final error = await ref
        .read(collectionControllerProvider.notifier)
        .remove(entry.workId);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error == null ? '已取消收藏' : error.userMessage),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final status = entry.status;

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppLayout.cardRadius),
        onTap: () => context.push(RoutePaths.workDetail(entry.workId)),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CoverImage(
                url: entry.coverUrl,
                width: AppLayout.coverWidth,
                height: AppLayout.coverHeight,
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
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        WorkTypeTag(type: entry.workType),
                        _StatusMenu(
                          status: status,
                          onSelected: (value) =>
                              _changeStatus(context, ref, value),
                        ),
                        if (entry.updatedAt != null)
                          Text(
                            _relativeTime(entry.updatedAt!),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '取消收藏',
                onPressed: () => _remove(context, ref),
                icon: const Icon(Icons.bookmark_remove_outlined),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 状态选择器。`null`（清除状态）与三个枚举值并列，因为「收藏但不设状态」
/// 是合法状态，不能只能通过删除收藏来表达。
class _StatusMenu extends StatelessWidget {
  const _StatusMenu({required this.status, required this.onSelected});

  static const String _clearStatusValue = '__none__';

  final CollectionStatus? status;
  final ValueChanged<CollectionStatus?> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = status?.label ?? '未设状态';

    return PopupMenuButton<String>(
      tooltip: '修改观看状态',
      // 不能用 `value: null` 表示「清除状态」：PopupMenuButton 把 null
      // 当成「用户点了外面取消」，onSelected 根本不会触发。用哨兵字符串。
      onSelected: (value) => onSelected(
        value == _clearStatusValue ? null : CollectionStatus.parse(value),
      ),
      itemBuilder: (context) => [
        for (final option in CollectionStatus.values)
          PopupMenuItem<String>(
            value: option.value,
            child: Text(option.label),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: _clearStatusValue,
          child: Text('清除状态'),
        ),
      ],
      child: Chip(
        visualDensity: VisualDensity.compact,
        label: Text(label),
        avatar: Icon(
          status == null ? Icons.help_outline : Icons.playlist_add_check,
          size: 16,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// 相对时间。列表里不需要精确到秒，够判断「最近改过」就行。
String _relativeTime(DateTime time) {
  final diff = DateTime.now().toUtc().difference(time.toUtc());
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (diff.inDays < 1) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  return time.toLocal().toString().substring(0, 10);
}
