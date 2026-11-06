import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'my_comment.dart';
import 'my_comment_mock_data_source.dart';

/// 「我的评论」的**唯一数据入口**。
///
/// 本轮按「有这个功能但不用」的口径：模块（model / 列表 / 四态 / 测试）全部
/// 备好，但个人空间的入口标「未开放」、不可点，这里也**只给 mock、不发真请求**。
/// 后端 `GET /api/me/comments`（#449 / PR #459）已随 b31 上线，契约也定稿了，
/// 所以不存在「等接口」的问题——不启用是产品决定，不是技术阻塞。
///
/// ⚠️ **这个签名没有分页**：`fetchAll` 一次性拿全量，而契约是
/// `?page=&page_size=`（默认 20、上限 50）。现在无所谓——mock 只有几条；
/// 但接真接口时**必须先改签名**，否则只会拿到第一页 50 条、界面却当成
/// 「全部」，用户会以为更早的评论丢了。
///
/// 改签名会牵连 [myCommentControllerProvider]（要加 `loadMore`）与页面
/// （要加滚动加载，四态还要区分「首屏空」与「加载更多失败」）。
/// **不是「只换实现」那么轻**——这也是把这条功能留到后面做的原因之一。
abstract interface class MyCommentDataSource {
  Future<List<MyComment>> fetchAll({required String userId});
}

/// 切换真接口的入口。启用时要做三件事（**前提：接口已按分页实现**）：
///
/// 1. 新建 `my_comment_remote_data_source.dart`，解 `GET /api/me/comments` 的
///    `items` 与 `PagedResult` 的分页字段；
/// 2. 这里按 `AppConfig.useMock` 切到 remote 实现；
/// 3. 给 `profile_page.dart` 的「我的评论」`_SectionTile` 补
///    `onTap: () => context.push(RoutePaths.myComment)`。
///
/// 第 1 步会连带改接口签名、controller 与页面（见上）；model 不用动。
final myCommentDataSourceProvider = Provider<MyCommentDataSource>((ref) {
  return const MyCommentMockDataSource();
});
