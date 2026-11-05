import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import 'article_favorite_data_source.dart';
import 'article_favorite_entry.dart';

/// 我收藏的资讯。
///
/// 两个「自动」行为与作品收藏一致，都是为了少写清理代码：
/// - `watch` 当前 `user_id`：切账号 / 退出登录时自动重建，不残留上一个账号的列表；
/// - 未登录不查：界面此时显示登录引导，而不是空列表 + 报错。
class ArticleFavoriteController
    extends AsyncNotifier<List<ArticleFavoriteEntry>> {
  @override
  Future<List<ArticleFavoriteEntry>> build() async {
    final userId = ref.watch(
      authControllerProvider.select((state) => state.user?.userId),
    );
    if (userId == null) return const <ArticleFavoriteEntry>[];
    return ref
        .watch(articleFavoriteDataSourceProvider)
        .fetchAll(userId: userId);
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
    AsyncNotifierProvider<ArticleFavoriteController, List<ArticleFavoriteEntry>>(
      ArticleFavoriteController.new,
      // 与全站一致：失败要显式呈现，自动重试会让失败看起来像一直在加载。
      retry: (retryCount, error) => null,
    );
