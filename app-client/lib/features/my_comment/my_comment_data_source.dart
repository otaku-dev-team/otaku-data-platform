import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'my_comment.dart';
import 'my_comment_mock_data_source.dart';

/// 「我的评论」的**唯一数据入口**。
///
/// 本轮按「有这个功能但不用」的口径：模块（model / 列表 / 四态 / 测试）全部
/// 备好，但个人空间的入口标「未开放」、不可点，这里也**只给 mock、不发真请求**。
/// 后端 `GET /api/me/comments`（#449 / PR #459）已随 b31 上线，契约也定稿了，
/// 所以不存在「等接口」的问题——不启用是产品决定，不是技术阻塞。
abstract interface class MyCommentDataSource {
  Future<List<MyComment>> fetchAll({required String userId});
}

/// 切换真接口的唯一入口。要开放这条功能时按三步走：
/// 1. 新建 `my_comment_remote_data_source.dart`，按 `MyComment.fromJson`
///    解 `GET /api/me/comments` 的 `items`，分页沿用 `PagedResult`；
/// 2. 这里改成 `AppConfig.useMock ? Mock() : Remote(ref.watch(dioProvider))`；
/// 3. 给 `profile_page.dart` 的「我的评论」`_SectionTile` 补上
///    `onTap: () => context.push(RoutePaths.myComment)`。
///
/// 页面、控制器、model **一行都不用改**。
final myCommentDataSourceProvider = Provider<MyCommentDataSource>((ref) {
  return const MyCommentMockDataSource();
});
