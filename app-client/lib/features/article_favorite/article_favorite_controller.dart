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

  Future<void> refresh() async {
    final userId = ref.read(authControllerProvider).user?.userId;
    if (userId == null) {
      state = const AsyncData(<ArticleFavoriteEntry>[]);
      return;
    }
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref
          .read(articleFavoriteDataSourceProvider)
          .fetchAll(userId: userId),
    );
  }
}

final articleFavoriteControllerProvider =
    AsyncNotifierProvider<ArticleFavoriteController, List<ArticleFavoriteEntry>>(
      ArticleFavoriteController.new,
      // 与全站一致：失败要显式呈现，自动重试会让失败看起来像一直在加载。
      retry: (retryCount, error) => null,
    );
