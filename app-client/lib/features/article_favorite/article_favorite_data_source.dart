import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/dio_client.dart';
import '../../data/models/article.dart';
import '../../data/models/paged_result.dart';
import '../auth/auth_controller.dart';
import 'article_favorite_entry.dart';
import 'article_favorite_mock_data_source.dart';

/// 资讯收藏（`/api/me/article-favorites`，契约 #377 / 后端 #507）。
///
/// 2026-11-07 接口上线：从「只读骨架」补成完整读写。
///
/// 三条语义直接决定实现：
///
/// 1. **单条状态「未收藏」是 `200` + `favorited: false`**，不是 `404`——
///    只有资讯本身不存在才 `404`。所以 [isFavorited] 不需要 try/catch；
/// 2. **`PUT` / `DELETE` 都幂等**：重复收藏、取消一个本来没收藏的，都不报错；
/// 3. 列表**分页**（`page` / `page_size`，超过 50 按 50 截断、不报错）。
abstract interface class ArticleFavoriteDataSource {
  Future<PagedResult<ArticleFavoriteEntry>> fetchPage({
    int page,
    int pageSize,
  });

  Future<bool> isFavorited(String articleId);

  Future<void> favorite(String articleId);

  Future<void> unfavorite(String articleId);
}

class ArticleFavoriteRemoteDataSource implements ArticleFavoriteDataSource {
  const ArticleFavoriteRemoteDataSource(this._dio);

  final Dio _dio;

  static const String basePath = '/api/me/article-favorites';

  /// `article_id` 是**不透明字符串**：只透传，不解析。整值编码，
  /// 免得带 `/` 之类字符时把路径拼歪（与人物页同一处理）。
  static String _path(String articleId) =>
      '$basePath/${Uri.encodeComponent(articleId)}';

  @override
  Future<PagedResult<ArticleFavoriteEntry>> fetchPage({
    int page = 1,
    int pageSize = 20,
  }) async {
    final response = await _dio.get<Map<String, dynamic>>(
      basePath,
      queryParameters: <String, dynamic>{'page': page, 'page_size': pageSize},
    );
    final data = response.data;
    if (data == null) {
      throw const ApiException(
        code: ApiErrorCode.unknown,
        message: '服务端返回了空响应',
      );
    }
    return PagedResult<ArticleFavoriteEntry>.fromJson(data, _entry);
  }

  @override
  Future<bool> isFavorited(String articleId) async {
    final response = await _dio.get<Map<String, dynamic>>(_path(articleId));
    // 未收藏也是 200，所以这里只判断字段，不靠状态码。
    return response.data?['favorited'] == true;
  }

  @override
  Future<void> favorite(String articleId) => _dio.put<void>(_path(articleId));

  @override
  Future<void> unfavorite(String articleId) =>
      _dio.delete<void>(_path(articleId));

  /// `ArticleFavoriteItem{article, favorited_at}` → [ArticleFavoriteEntry]。
  ///
  /// 单条坏数据抛 [FormatException]，由 `PagedResult.fromJson` 跳过——
  /// 一条脏数据不该让整页收藏变空。
  static ArticleFavoriteEntry _entry(Map<String, dynamic> json) {
    final article = json['article'];
    if (article is! Map) {
      throw const FormatException('article 缺失');
    }
    return ArticleFavoriteEntry(
      article: ArticleSummary.fromJson(Map<String, dynamic>.from(article)),
      favoritedAt: _date(json['favorited_at']),
    );
  }

  static DateTime? _date(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }
}

/// 切换真接口的唯一入口。
final articleFavoriteDataSourceProvider = Provider<ArticleFavoriteDataSource>((
  ref,
) {
  if (AppConfig.useMock) return ArticleFavoriteMockDataSource();
  return ArticleFavoriteRemoteDataSource(ref.watch(dioProvider));
});

/// 是否该查收藏状态。
///
/// **游客不查**：`/api/me/article-favorites/{id}` 要登录，硬打会拿 401，
/// 而 dio 的 401 拦截器会广播「会话已过期」——刷个资讯详情页就把登录态踢掉。
final articleFavoriteAudienceProvider = Provider<bool>(
  (ref) => ref.watch(authControllerProvider).isSignedIn,
);

/// 单条资讯的收藏状态。
///
/// 「未收藏」是正常结果（`200` + `favorited: false`），所以这里不抛错、
/// 也不把「查不到」当成「没收藏」以外的含义。
final articleFavoriteStatusProvider = FutureProvider.family<bool, String>((
  ref,
  articleId,
) async {
  if (!ref.watch(articleFavoriteAudienceProvider)) return false;
  return ref.watch(articleFavoriteDataSourceProvider).isFavorited(articleId);
  // 与全站一致：失败要显式呈现，自动重试会让按钮一直转圈。
}, retry: (retryCount, error) => null);
