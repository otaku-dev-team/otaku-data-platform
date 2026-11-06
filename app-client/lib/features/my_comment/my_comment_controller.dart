import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import 'my_comment.dart';
import 'my_comment_data_source.dart';

/// 我的评论列表。
///
/// 两个「自动」行为与收藏一致：
/// - `watch` 当前 `user_id`：切账号 / 退出登录时自动重建，不残留上一个账号的评论；
/// - 未登录不查：界面此时显示登录引导，而不是空列表 + 报错。
class MyCommentController extends AsyncNotifier<List<MyComment>> {
  @override
  Future<List<MyComment>> build() async {
    final userId = ref.watch(
      authControllerProvider.select((state) => state.user?.userId),
    );
    if (userId == null) return const <MyComment>[];
    return ref.watch(myCommentDataSourceProvider).fetchAll(userId: userId);
  }

  /// 刷新期间保留旧列表，避免点一次刷新就闪一下骨架屏。
  Future<void> refresh() async {
    ref.invalidateSelf();
    try {
      await future;
    } on Object {
      // 忽略：错误已经进 AsyncError，由页面呈现。
    }
  }
}

final myCommentControllerProvider =
    AsyncNotifierProvider<MyCommentController, List<MyComment>>(
      MyCommentController.new,
      // 与全站一致：失败要显式呈现，自动重试会让失败看起来像一直在加载。
      retry: (retryCount, error) => null,
    );
