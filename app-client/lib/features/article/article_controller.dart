import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/article.dart';
import '../../data/repositories/article_repository.dart';

/// 资讯列表的筛选条件。
@immutable
class ArticleFilter {
  const ArticleFilter({this.category});

  /// 分类徽章原文。`null` 表示不过滤。
  ///
  /// 值来自 [ArticleFilterController.selectCategory]，已经 trim；
  /// 直接构造时不要塞未归一的字符串。
  final String? category;

  @override
  bool operator ==(Object other) =>
      other is ArticleFilter && other.category == category;

  @override
  int get hashCode => category.hashCode;
}

class ArticleFilterController extends Notifier<ArticleFilter> {
  @override
  ArticleFilter build() => const ArticleFilter();

  /// 传 `null` 表示"全部分类"。再点一次当前分类就是取消。
  void selectCategory(String? category) {
    final normalized = category?.trim();
    final next = (normalized == null || normalized.isEmpty) ? null : normalized;
    if (state.category == next) return;
    state = ArticleFilter(category: next);
  }
}

final articleFilterProvider =
    NotifierProvider<ArticleFilterController, ArticleFilter>(
  ArticleFilterController.new,
);

/// 列表页状态：已加载条目 + 分页进度 + 加载更多的失败信息。
///
/// 沿用作品列表的形状：首屏错误走 [AsyncError]，分页错误走
/// [loadMoreError]——两者必须分开，否则加载下一页失败会把已看到的
/// 内容清空。
@immutable
class ArticleListData {
  const ArticleListData({
    required this.filter,
    required this.items,
    required this.page,
    required this.total,
    required this.totalPages,
    this.isLoadingMore = false,
    this.loadMoreError,
  });

  final ArticleFilter filter;
  final List<ArticleSummary> items;
  final int page;
  final int total;
  final int totalPages;
  final bool isLoadingMore;
  final Object? loadMoreError;

  bool get hasMore => page < totalPages;

  ArticleListData copyWith({
    List<ArticleSummary>? items,
    int? page,
    int? total,
    int? totalPages,
    bool? isLoadingMore,
    Object? loadMoreError,
    bool clearLoadMoreError = false,
  }) {
    return ArticleListData(
      filter: filter,
      items: items ?? this.items,
      page: page ?? this.page,
      total: total ?? this.total,
      totalPages: totalPages ?? this.totalPages,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      loadMoreError: clearLoadMoreError
          ? null
          : (loadMoreError ?? this.loadMoreError),
    );
  }
}

class ArticleListController extends AsyncNotifier<ArticleListData> {
  @override
  Future<ArticleListData> build() async {
    // 条件变化时 build 重跑，等于自动重新查第一页。
    final filter = ref.watch(articleFilterProvider);
    final result = await ref.watch(articleRepositoryProvider).fetchArticles(
      category: filter.category,
      page: 1,
    );

    return ArticleListData(
      filter: filter,
      items: result.items,
      page: result.page,
      total: result.total,
      totalPages: result.totalPages,
    );
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || current.isLoadingMore || !current.hasMore) return;

    state = AsyncData(
      current.copyWith(isLoadingMore: true, clearLoadMoreError: true),
    );

    final filter = ref.read(articleFilterProvider);
    try {
      final next = await ref
          .read(articleRepositoryProvider)
          .fetchArticles(
            category: filter.category,
            // 翻页必须带同一 category：不带就退回全部分类，
            // 第 2 页会和第 1 页接不上（重复或漏条）。
            page: current.page + 1,
          );

      // 请求返回时条件可能已经变了，过期结果直接丢弃。
      if (!ref.mounted || ref.read(articleFilterProvider) != filter) return;

      state = AsyncData(
        current.copyWith(
          items: [...current.items, ...next.items],
          page: next.page,
          total: next.total,
          totalPages: next.totalPages,
          isLoadingMore: false,
          clearLoadMoreError: true,
        ),
      );
    } on Object catch (error) {
      if (!ref.mounted) return;
      state = AsyncData(
        current.copyWith(isLoadingMore: false, loadMoreError: error),
      );
    }
  }

  /// 下拉刷新 / 重试。错误由 state 呈现，这里只负责让下拉动画结束。
  Future<void> refresh() async {
    ref.invalidateSelf();
    try {
      await future;
    } on Object {
      // 忽略：build 抛出的异常已经变成 AsyncError 了。
    }
  }
}

final articleListControllerProvider =
    AsyncNotifierProvider<ArticleListController, ArticleListData>(
  ArticleListController.new,
  // 契约要求错误必须显式呈现；自动重试会让失败看起来像"一直在加载"。
  retry: (retryCount, error) => null,
);

/// 分类筛选项。分类是从数据里聚合出来的，变了要重新查；
/// 失败时给空列表而不是把整个页面拖进错误态——
/// 分类 chips 只是筛选辅助，没有它用户照样能看全部资讯。
final articleCategoriesProvider = FutureProvider<List<ArticleCategory>>(
  (ref) {
    return ref.watch(articleRepositoryProvider).fetchCategories();
  },
  // 关掉自动重试：拿不到就不显示 chips，没必要在后台一直重试。
  retry: (retryCount, error) => null,
);

/// 资讯详情。`articleId` 变了就重查。
///
/// 显式关掉 Riverpod 3 的自动重试（与 `workDetailProvider` 同一个理由）：
/// 404 要提示「资讯不存在」并让用户返回列表，而不是在后台反复重试；
/// 带着 retry 的失败态是 `AsyncLoading(error: …)`，界面会永远停在骨架屏上。
final articleDetailProvider =
    FutureProvider.autoDispose.family<ArticleDetail, String>(
  (ref, articleId) {
    return ref.watch(articleRepositoryProvider).fetchDetail(articleId);
  },
  retry: (retryCount, error) => null,
);