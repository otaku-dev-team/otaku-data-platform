import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';
import '../../data/models/article.dart';
import '../../shared/widgets/desktop_nav_shell.dart';
import '../../shared/widgets/mobile_nav_bar.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/error_state.dart';
import 'article_card.dart';
import 'article_controller.dart';

/// 最新资讯列表：分类筛选 + 无限滚动分页。
///
/// 状态矩阵（与作品列表同一套，验收时逐条对）：
/// - 首屏加载 → 骨架屏
/// - 无数据 / 该分类下无数据 → 空状态（文案区分「没有资讯」与「这个分类下没有」）
/// - 首屏失败 → 错误状态 + 重试
/// - 加载下一页失败 → 底部重试条，**不清空已有数据**
class ArticleListPage extends ConsumerStatefulWidget {
  const ArticleListPage({super.key});

  @override
  ConsumerState<ArticleListPage> createState() => _ArticleListPageState();
}

class _ArticleListPageState extends ConsumerState<ArticleListPage> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.maxScrollExtent - position.pixels < 320) {
      ref.read(articleListControllerProvider.notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(articleFilterProvider);
    final list = ref.watch(articleListControllerProvider);
    final categories = ref.watch(articleCategoriesProvider);

    return DesktopNavShell(
      child: Scaffold(
        bottomNavigationBar: MobileNavBar.forScaffold(context),
        appBar: AppBar(
          title: const Text('最新资讯'),
          actions: [
            IconButton(
              tooltip: '作品库',
              onPressed: () => context.go(RoutePaths.contents),
              icon: const Icon(Icons.video_library_outlined),
            ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppLayout.listMaxWidth),
            child: Column(
              children: [
                _CategoryRow(
                  selected: filter.category,
                  categories: categories.value ?? const [],
                  total: list.value?.total,
                  onSelected: (category) => ref
                      .read(articleFilterProvider.notifier)
                      .selectCategory(category),
                ),
                Expanded(child: _buildBody(filter, list)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ArticleFilter filter, AsyncValue<ArticleListData> list) {
    final data = list.value;
    // 换条件后 Riverpod 会把上一组数据留在 AsyncLoading/AsyncError 里，
    // 那份数据不属于当前条件，不能当结果显示。
    final isStale = data != null && data.filter != filter;

    if (list.isLoading && (data == null || isStale)) {
      return const _ArticleSkeleton();
    }

    if (list.hasError) {
      final error = ApiException.fromAny(list.error);
      if (data == null || isStale) {
        return ErrorState(
          error: error,
          onRetry: () => ref.invalidate(articleListControllerProvider),
        );
      }
      return Column(
        children: [
          _LoadMoreErrorBar(
            error: error,
            onRetry: () =>
                ref.read(articleListControllerProvider.notifier).loadMore(),
          ),
          Expanded(child: _buildList(data)),
        ],
      );
    }

    final resolved = list.requireValue;
    if (resolved.items.isEmpty) return _buildEmpty(filter);
    return _buildList(resolved);
  }

  Widget _buildEmpty(ArticleFilter filter) {
    final category = filter.category;
    return RefreshIndicator(
      onRefresh: () =>
          ref.read(articleListControllerProvider.notifier).refresh(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 72),
          EmptyState(
            icon: category == null
                ? Icons.newspaper_outlined
                : Icons.filter_alt_off_outlined,
            title: category == null ? '还没有资讯' : '这个分类下暂时没有资讯',
            message: category == null
                ? '等同步任务跑完就有了'
                : '换个分类看看，或点「全部」看所有资讯',
          ),
        ],
      ),
    );
  }

  Widget _buildList(ArticleListData data) {
    return RefreshIndicator(
      onRefresh: () =>
          ref.read(articleListControllerProvider.notifier).refresh(),
      child: ListView.separated(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppLayout.pagePadding,
          8,
          AppLayout.pagePadding,
          24,
        ),
        itemCount: data.items.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (index == data.items.length) {
            return _buildFooter(data);
          }
          final item = data.items[index];
          return ArticleCard(
            article: item,
            onTap: () => context.push(RoutePaths.articleDetail(item.articleId)),
          );
        },
      ),
    );
  }

  Widget _buildFooter(ArticleListData data) {
    if (data.isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (data.loadMoreError != null) {
      return _LoadMoreErrorBar(
        error: ApiException.fromAny(data.loadMoreError),
        onRetry: () =>
            ref.read(articleListControllerProvider.notifier).loadMore(),
      );
    }
    if (!data.hasMore && data.items.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text(
            '已经到底了，共 ${data.total} 条',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
      );
    }
    return const SizedBox(height: 8);
  }
}

/// 分类 chips。没有分类数据时整行不渲染——
/// 一排空 chips 会让人以为这里本来该有东西却加载失败了。
class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.selected,
    required this.categories,
    required this.total,
    required this.onSelected,
  });

  final String? selected;
  final List<ArticleCategory> categories;
  final int? total;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    if (categories.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(
          left: AppLayout.pagePadding,
          right: AppLayout.pagePadding,
        ),
        children: [
          _chip(context, label: '全部', count: total, isSelected: selected == null, onTap: () => onSelected(null)),
          for (final category in categories)
            _chip(
              context,
              label: category.name,
              count: category.count,
              isSelected: selected == category.name,
              onTap: () => onSelected(category.name),
            ),
        ],
      ),
    );
  }

  Widget _chip(
    BuildContext context, {
    required String label,
    required int? count,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8, top: 8, bottom: 8),
      child: ChoiceChip(
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label),
            if (count != null) ...[
              const SizedBox(width: 6),
              Text(
                '$count',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ],
        ),
        selected: isSelected,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

/// 首屏骨架。与列表项同构，切换分类不会跳一下。
class _ArticleSkeleton extends StatelessWidget {
  const _ArticleSkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView.separated(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        AppLayout.pagePadding,
        8,
        AppLayout.pagePadding,
        24,
      ),
      itemCount: 6,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) => Container(
        height: 96,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
}

/// 加载更多失败时的条。保留已有内容，只把失败与重试入口摆在列表下方。
class _LoadMoreErrorBar extends StatelessWidget {
  const _LoadMoreErrorBar({required this.error, required this.onRetry});

  final ApiException error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppLayout.pagePadding,
        8,
        AppLayout.pagePadding,
        0,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 16, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '加载更多失败：${error.message}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onErrorContainer,
                  ),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              foregroundColor: scheme.onErrorContainer,
              visualDensity: VisualDensity.compact,
            ),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}