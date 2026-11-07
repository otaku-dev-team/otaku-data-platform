import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/platform_info.dart';
import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/error_state.dart';
import '../../shared/widgets/skeleton_list.dart';
import '../article/article_card.dart';
import 'article_favorite_controller.dart';
import 'article_favorite_entry.dart';

/// 收藏页「资讯」分段的内容。
///
/// 四态与作品收藏逐条对齐：加载骨架、失败 + 重试、空态、列表。
/// 卡片直接复用资讯流的 [ArticleCard]，切分段时不会有「换了个产品」的割裂感。
///
/// 2026-11-07 接口上线后从「只读骨架」补成可读可取消：滚动到底自动加载下一页，
/// 加载失败只影响底部那一条重试，不清空已经看到的内容；取消收藏是**乐观移除**，
/// 失败会插回原位并提示。
class ArticleFavoriteList extends ConsumerStatefulWidget {
  const ArticleFavoriteList({super.key});

  @override
  ConsumerState<ArticleFavoriteList> createState() =>
      _ArticleFavoriteListState();
}

class _ArticleFavoriteListState extends ConsumerState<ArticleFavoriteList> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_maybeLoadMore);
    _scrollController.dispose();
    super.dispose();
  }

  /// 提前 400px 触发：等滚到底再请求，用户会先看到一段空白。
  void _maybeLoadMore() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels < position.maxScrollExtent - 400) return;
    // `loadMore` 内部自己判 isLoadingMore / hasMore，重复调用是安全的。
    ref.read(articleFavoriteControllerProvider.notifier).loadMore();
  }

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(articleFavoriteControllerProvider);

    if (value.isLoading && !value.hasValue) return const SkeletonList();

    if (value.hasError && !value.hasValue) {
      return ErrorState(
        error: ApiException.fromAny(value.error),
        onRetry: () =>
            ref.read(articleFavoriteControllerProvider.notifier).refresh(),
      );
    }

    final data = value.value;
    final items = data?.items ?? const <ArticleFavoriteEntry>[];

    if (items.isEmpty) {
      return EmptyState(
        icon: Icons.bookmark_border_rounded,
        title: '还没有收藏的资讯',
        message: '在资讯详情页点收藏，就会出现在这里。',
        // 桌面端不给按钮：资讯流的入口在侧栏一直可见，这条空态里再放一个
        // 只是重复。手机上没有常驻入口，才需要给一条路。
        action: PlatformInfo.isDesktop
            ? null
            : FilledButton.tonal(
                onPressed: () => context.go(RoutePaths.articles),
                child: const Text('去看看资讯'),
              ),
      );
    }

    return RefreshIndicator(
      color: AppTheme.brandStrong,
      onRefresh: () =>
          ref.read(articleFavoriteControllerProvider.notifier).refresh(),
      child: ListView.separated(
        controller: _scrollController,
        // 切分段会销毁这一支；同一个 PageStorageKey 让滚动位置在切回来时恢复，
        // 不用从顶部重新翻。
        key: const PageStorageKey<String>('article-favorite-list'),
        padding: const EdgeInsets.fromLTRB(
          AppLayout.pagePadding,
          8,
          AppLayout.pagePadding,
          Space.s6,
        ),
        // 内容不满一屏也要能下拉刷新：跨端收藏后不必退出这一页。
        physics: const AlwaysScrollableScrollPhysics(),
        // 末尾多一格放「加载更多」的状态条。
        itemCount: items.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: Space.s2),
        itemBuilder: (context, index) {
          if (index == items.length) {
            return _footer(data);
          }
          final entry = items[index];
          return _FavoriteTile(
            entry: entry,
            onRemove: () => _remove(entry),
          );
        },
      ),
    );
  }

  Widget _footer(ArticleFavoriteData? data) {
    if (data == null) return const SizedBox(height: Space.s2);

    if (data.loadMoreError != null) {
      return Padding(
        padding: const EdgeInsets.only(top: Space.s3),
        child: Center(
          child: TextButton.icon(
            onPressed: () =>
                ref.read(articleFavoriteControllerProvider.notifier).loadMore(),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('没加载出来，重试'),
          ),
        ),
      );
    }
    if (data.isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: Space.s4),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    // 到底了就不再占位，避免列表尾部多出一片空白。
    if (!data.hasMore) return const SizedBox(height: Space.s2);
    return const SizedBox(height: Space.s4);
  }

  Future<void> _remove(ArticleFavoriteEntry entry) async {
    final error = await ref
        .read(articleFavoriteControllerProvider.notifier)
        .remove(entry.article.articleId);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error.userMessage)));
    } else {
      messenger.showSnackBar(const SnackBar(content: Text('已取消收藏')));
    }
  }
}

class _FavoriteTile extends StatelessWidget {
  const _FavoriteTile({required this.entry, required this.onRemove});

  final ArticleFavoriteEntry entry;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final favoritedAt = entry.favoritedAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ArticleCard(
          article: entry.article,
          onTap: () =>
              context.push(RoutePaths.articleDetail(entry.article.articleId)),
        ),
        // 收藏时间与「取消」同一行：它们都是「我和这条资讯的关系」，
        // 而卡片里那行元信息讲的是「这条资讯是什么」。
        Padding(
          padding: const EdgeInsets.only(left: 12, right: 4),
          child: Row(
            children: [
              if (favoritedAt != null)
                Expanded(
                  child: Text(
                    '收藏于 ${_formatFavoritedAt(favoritedAt)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                const Spacer(),
              TextButton(
                onPressed: onRemove,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: theme.colorScheme.onSurfaceVariant,
                ),
                child: const Text('取消收藏'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 只到「日」：收藏时间的用途是「什么时候收的」，精确到秒没有意义；
/// 统一按本地时区显示，服务端给的是 UTC。
String _formatFavoritedAt(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}';
}
