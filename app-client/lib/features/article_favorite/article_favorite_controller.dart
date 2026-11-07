import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../data/models/paged_result.dart';
import '../auth/auth_controller.dart';
import 'article_favorite_data_source.dart';
import 'article_favorite_entry.dart';

/// 资讯收藏列表的完整状态：已加载的数据 + 分页进度 + 加载更多的失败信息。
///
/// 首屏错误走 `AsyncError`，分页错误走 [loadMoreError]——两者**必须分开**，
/// 否则加载下一页失败会把已经看到的内容清空（与作品库同一口径）。
@immutable
class ArticleFavoriteData {
  const ArticleFavoriteData({
    required this.items,
    required this.page,
    required this.total,
    required this.totalPages,
    this.isLoadingMore = false,
    this.loadMoreError,
  });

  final List<ArticleFavoriteEntry> items;
  final int page;
  final int total;
  final int totalPages;
  final bool isLoadingMore;
  final ApiException? loadMoreError;

  bool get hasMore => page < totalPages;

  ArticleFavoriteData copyWith({
    List<ArticleFavoriteEntry>? items,
    int? page,
    int? total,
    int? totalPages,
    bool? isLoadingMore,
    ApiException? loadMoreError,
    bool clearLoadMoreError = false,
  }) {
    return ArticleFavoriteData(
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

/// 我收藏的资讯。
///
/// 两个「自动」行为与作品收藏一致，都是为了少写清理代码：
/// - `watch` 当前 `user_id`：切账号 / 退出登录时自动重建，不残留上一个账号的列表；
/// - 未登录不查：界面此时显示登录引导，而不是空列表 + 报错。
class ArticleFavoriteController extends AsyncNotifier<ArticleFavoriteData> {
  static const int pageSize = 20;

  @override
  Future<ArticleFavoriteData> build() async {
    final userId = ref.watch(
      authControllerProvider.select((state) => state.user?.userId),
    );
    if (userId == null) {
      return const ArticleFavoriteData(
        items: <ArticleFavoriteEntry>[],
        page: 1,
        total: 0,
        totalPages: 0,
      );
    }
    final page = await ref
        .watch(articleFavoriteDataSourceProvider)
        .fetchPage(page: 1, pageSize: pageSize);
    return _fromPage(page);
  }

  static ArticleFavoriteData _fromPage(
    PagedResult<ArticleFavoriteEntry> page,
  ) => ArticleFavoriteData(
    items: page.items,
    page: page.page,
    total: page.total,
    totalPages: page.totalPages,
  );

  /// 加载下一页。失败只记在 [ArticleFavoriteData.loadMoreError]，
  /// 不动已有列表——用户还能继续看已经加载出来的那些。
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || current.isLoadingMore || !current.hasMore) return;

    state = AsyncData(
      current.copyWith(isLoadingMore: true, clearLoadMoreError: true),
    );
    try {
      final next = await ref
          .read(articleFavoriteDataSourceProvider)
          .fetchPage(page: current.page + 1, pageSize: pageSize);
      state = AsyncData(
        current.copyWith(
          items: <ArticleFavoriteEntry>[...current.items, ...next.items],
          page: next.page,
          total: next.total,
          totalPages: next.totalPages,
          isLoadingMore: false,
        ),
      );
    } on ApiException catch (error) {
      state = AsyncData(
        current.copyWith(isLoadingMore: false, loadMoreError: error),
      );
    } on Object {
      state = AsyncData(
        current.copyWith(
          isLoadingMore: false,
          loadMoreError: const ApiException(
            code: ApiErrorCode.unknown,
            message: '加载更多失败，请重试',
          ),
        ),
      );
    }
  }

  /// 取消收藏。**乐观移除**：先从列表拿掉（用户不用等一次往返），
  /// 失败再插回原位并把错误交给页面提示。
  ///
  /// 返回 `null` 表示成功。
  Future<ApiException?> remove(String articleId) async {
    final current = state.value;
    if (current == null) return null;

    final index = current.items.indexWhere(
      (entry) => entry.article.articleId == articleId,
    );
    if (index < 0) return null;
    final removed = current.items[index];

    state = AsyncData(
      current.copyWith(
        items: <ArticleFavoriteEntry>[...current.items]..removeAt(index),
        total: current.total > 0 ? current.total - 1 : 0,
      ),
    );

    try {
      await ref.read(articleFavoriteDataSourceProvider).unfavorite(articleId);
      return null;
    } on ApiException catch (error) {
      _restore(index, removed);
      return error;
    } on Object {
      _restore(index, removed);
      return const ApiException(
        code: ApiErrorCode.unknown,
        message: '取消收藏失败，请重试',
      );
    }
  }

  void _restore(int index, ArticleFavoriteEntry entry) {
    final now = state.value;
    if (now == null) return;
    final items = <ArticleFavoriteEntry>[...now.items];
    items.insert(index.clamp(0, items.length), entry);
    state = AsyncData(now.copyWith(items: items, total: now.total + 1));
  }

  /// 刷新期间**保留旧列表**：与作品收藏同一写法（`invalidateSelf` + `await future`），
  /// Riverpod 会把旧值带进 `AsyncLoading`。若这里改成 `state = AsyncLoading()`，
  /// 列表会先变成骨架屏再回来——用户点一次刷新，眼睛被闪一下。
  Future<void> refresh() async {
    ref.invalidateSelf();
    try {
      await future;
    } on Object {
      // 忽略：错误已经进 AsyncError，由页面呈现。
    }
  }
}

final articleFavoriteControllerProvider =
    AsyncNotifierProvider<
      ArticleFavoriteController,
      ArticleFavoriteData
    >(
      ArticleFavoriteController.new,
      // 与全站一致：失败要显式呈现，自动重试会让失败看起来像一直在加载。
      retry: (retryCount, error) => null,
    );
