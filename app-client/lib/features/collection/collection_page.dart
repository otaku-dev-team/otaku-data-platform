import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/collection_entry.dart';
import '../../data/repositories/work_repository.dart' show Fetched;
import '../../shared/widgets/account_menu.dart';
import '../../shared/widgets/desktop_nav_shell.dart';
import '../../shared/widgets/mobile_nav_bar.dart';
import '../../shared/widgets/desktop_shortcuts.dart';
import '../../shared/widgets/collection_status_menu.dart';
import '../../shared/widgets/cover_image.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/error_state.dart';
import '../../shared/widgets/offline_notice.dart';
import '../../shared/widgets/poster_card.dart';
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

    return DesktopNavShell(
      child: DesktopShortcuts(
        onRefresh: auth.isSignedIn
            ? () => ref.read(collectionControllerProvider.notifier).refresh()
            : null,
        child: Scaffold(
          bottomNavigationBar: MobileNavBar.forScaffold(context),
          appBar: AppBar(
            title: const Text('我的收藏'),
            actions: [
              if (auth.isSignedIn)
                IconButton(
                  tooltip: '刷新',
                  onPressed: () =>
                      ref.read(collectionControllerProvider.notifier).refresh(),
                  icon: const Icon(Icons.refresh),
                ),
              // 登录/账号入口与作品库共用同一个组件，未登录时也要能看到「登录」，
              // 否则这一页只剩一句提示，用户还得退出去找入口。
              const AccountMenuButton(),
            ],
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppLayout.listMaxWidth,
              ),
              child: switch (auth.status) {
                AuthStatus.checking => const SkeletonList(),
                AuthStatus.signedOut => const _SignInPrompt(),
                AuthStatus.signedIn => const _CollectionBody(),
              },
            ),
          ),
        ),
      ),
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

    // 离线提示放在筛选栏下、列表上，与作品库同一位置：先看到内容，
    // 紧接着看到「这是缓存」的说明，而不是被一条横幅挡在内容之外。
    final cached = collections.value;
    final offline = cached != null && cached.fromCache;

    return Column(
      children: [
        _StatusFilters(
          selected: filter,
          onSelected: (status) =>
              ref.read(collectionFilterProvider.notifier).select(status),
        ),
        if (offline)
          OfflineNotice(
            cachedAt: cached.cachedAt,
            onRetry: () =>
                ref.read(collectionControllerProvider.notifier).refresh(),
          ),
        Expanded(child: _buildList(context, ref, collections, filter)),
      ],
    );
  }

  Widget _buildList(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<Fetched<List<CollectionEntry>>> collections,
    CollectionStatus? filter,
  ) {
    final fetched = collections.value;
    final items = fetched?.value;
    if (collections.isLoading && items == null) return const SkeletonList();

    if (collections.hasError && items == null) {
      return ErrorState(
        error: ApiException.fromAny(collections.error),
        onRetry: () =>
            ref.read(collectionControllerProvider.notifier).refresh(),
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
      color: AppTheme.brandStrong,
      onRefresh: () =>
          ref.read(collectionControllerProvider.notifier).refresh(),
      // 与作品库同一套海报网格，两个页面切换时不会有"换了个版面"的割裂感。
      child: LayoutBuilder(
        builder: (context, constraints) {
          final usable = constraints.maxWidth - AppLayout.pagePadding * 2;
          final metrics = AppLayout.gridMetrics(usable);
          // 正文高度跟着系统字体缩放走：手机上把字体调大后，固定高度会撑爆
          // 卡片（Flutter 会画黄黑条纹），按缩放比一起放大才撑得住。
          final textScale = MediaQuery.textScalerOf(context).scale(1);
          final extent =
              metrics.cardWidth / AppLayout.posterAspect +
              AppLayout.collectionCardBodyHeight * textScale;

          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(
              AppLayout.pagePadding,
              4,
              AppLayout.pagePadding,
              24,
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: metrics.columns,
              mainAxisExtent: extent,
              crossAxisSpacing: AppLayout.gridGap,
              mainAxisSpacing: AppLayout.gridGap,
            ),
            itemCount: data.length,
            itemBuilder: (context, index) =>
                _CollectionTile(entry: data[index]),
          );
        },
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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(error.userMessage)));
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final error = await ref
        .read(collectionControllerProvider.notifier)
        .remove(entry.workId);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error == null ? '已取消收藏' : error.userMessage)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final status = entry.status;
    final firstChar = entry.title.characters.isEmpty
        ? null
        : entry.title.characters.first;
    final updatedAt = entry.updatedAt;
    // 网格的 mainAxisExtent 已按字号缩放（见上方 _buildGrid 一侧），正文容器
    // 必须用同一个缩放值，否则外壳够高、内部固定 124 依旧会裁掉标题和状态。
    // 真机 font_scale 2.0 实测：标题下半被裁、状态 chip 只剩一个字。
    final textScale = MediaQuery.textScalerOf(context).scale(1);

    return PosterCardShell(
      onTap: () => context.push(RoutePaths.workDetail(entry.workId)),
      overlay: _RemoveButton(onPressed: () => _remove(context, ref)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: AppLayout.posterAspect,
            child: CoverImage(
              url: entry.coverUrl,
              width: double.infinity,
              height: double.infinity,
              radius: 0,
              placeholderLabel: firstChar,
            ),
          ),
          SizedBox(
            height: AppLayout.collectionCardBodyHeight * textScale,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 标题用 Expanded 而不是固定 40：固定高度只在「标题正好两行、
                  // 其余元素尺寸不变」时才成立，字体一缩放就撑爆卡片。让标题
                  // 吃掉剩余空间，多出来的高度它自己承接，不会溢出到卡片外。
                  Expanded(
                    child: Text(
                      entry.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      WorkTypeTag(type: entry.workType),
                      const SizedBox(width: 6),
                      Flexible(
                        child: CollectionStatusMenu(
                          status: status,
                          onSelected: (value) =>
                              _changeStatus(context, ref, value),
                        ),
                      ),
                    ],
                  ),
                  if (updatedAt != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      _relativeTime(updatedAt),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 封面右上角的取消收藏。压在图上而不是占正文一行，正文只留给标题与状态。
class _RemoveButton extends StatelessWidget {
  const _RemoveButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '取消收藏',
      child: Material(
        color: Colors.black.withValues(alpha: 0.45),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: const Padding(
            padding: EdgeInsets.all(6),
            child: Icon(
              Icons.bookmark_remove_rounded,
              size: 16,
              color: Colors.white,
            ),
          ),
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
