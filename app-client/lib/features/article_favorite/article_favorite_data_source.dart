import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'article_favorite_entry.dart';
import 'article_favorite_mock_data_source.dart';

/// 资讯收藏的读取口。
///
/// 本轮是 #377 的**只读骨架**：接口尚未定稿，所以只有「拉列表」一个方法，
/// 没有 `remove`——取消收藏要等契约的幂等语义（`DELETE` 不存在也 204）
/// 定下来再写，否则只能对着一套猜的语义写状态机。
abstract class ArticleFavoriteDataSource {
  Future<List<ArticleFavoriteEntry>> fetchAll({required String userId});
}

/// 切换真接口的唯一入口。
///
/// 契约落地后按这三步接上（与 `articleDataSourceProvider` 同一套模式）：
/// 1. 新建 `article_favorite_remote_data_source.dart`，把响应映射成
///    [ArticleFavoriteEntry]；
/// 2. 这里改成 `AppConfig.useMock ? Mock() : Remote(ref.watch(dioProvider))`；
/// 3. 页面与控制器**一行不用改**。
final articleFavoriteDataSourceProvider = Provider<ArticleFavoriteDataSource>((
  ref,
) {
  return ArticleFavoriteMockDataSource();
});
