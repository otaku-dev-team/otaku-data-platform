import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
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
/// **只读**：本轮是骨架（#377 接口未定稿），没有取消收藏与批量操作。
/// 接口定稿后要加的是 `remove`，不是重写这个组件。
class ArticleFavoriteList extends ConsumerWidget {
  const ArticleFavoriteList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(articleFavoriteControllerProvider);

    if (value.isLoading && !value.hasValue) return const SkeletonList();

    if (value.hasError && !value.hasValue) {
      return ErrorState(
        error: ApiException.fromAny(value.error),
        onRetry: () =>
            ref.read(articleFavoriteControllerProvider.notifier).refresh(),
      );
    }

    final items = value.value ?? const <ArticleFavoriteEntry>[];
    if (items.isEmpty) {
      return const EmptyState(
        icon: Icons.bookmark_border_rounded,
        title: '还没有收藏的资讯',
        message: '在资讯详情页点收藏，就会出现在这里。',
      );
    }

    return RefreshIndicator(
      color: AppTheme.brandStrong,
      onRefresh: () =>
          ref.read(articleFavoriteControllerProvider.notifier).refresh(),
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(
          AppLayout.pagePadding,
          8,
          AppLayout.pagePadding,
          Space.s6,
        ),
        // 内容不满一屏也要能下拉刷新：跨端收藏后不必退出这一页。
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(height: Space.s2),
        itemBuilder: (context, index) {
          final entry = items[index];
          return ArticleCard(
            article: entry.article,
            onTap: () => context.push(
              RoutePaths.articleDetail(entry.article.articleId),
            ),
          );
        },
      ),
    );
  }
}
