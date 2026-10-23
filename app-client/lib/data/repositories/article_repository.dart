import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/dio_client.dart';
import '../datasources/article_data_source.dart';
import '../datasources/article_mock_data_source.dart';
import '../datasources/article_remote_data_source.dart';
import '../models/article.dart';
import '../models/paged_result.dart';

/// 资讯页面唯一的数据入口。职责与 `WorkRepository` 平行：
/// 把底层异常收敛成 [ApiException]，页面不认 dio 也不认 Mock。
class ArticleRepository {
  ArticleRepository(this._dataSource);

  final ArticleDataSource _dataSource;

  /// 一页资讯。[category] 省略或空串表示不过滤。
  Future<PagedResult<ArticleSummary>> fetchArticles({
    String? category,
    int page = 1,
    int pageSize = AppConfig.pageSize,
  }) async {
    try {
      return await _dataSource.fetchArticles(
        category: category,
        page: page,
        pageSize: pageSize,
      );
    } on ApiException {
      rethrow;
    } on DioException catch (error) {
      throw ApiException.fromDio(error);
    } on FormatException catch (error) {
      throw ApiException(
        code: ApiErrorCode.unknown,
        message: '数据格式异常：${error.message}',
      );
    }
  }

  /// 详情。不存在时 [ApiException] 的 code 是 `notFound`，
  /// 页面据此显示「资讯不存在」而不是网络错误。
  Future<ArticleDetail> fetchDetail(String articleId) async {
    try {
      return await _dataSource.fetchDetail(articleId);
    } on ApiException {
      rethrow;
    } on DioException catch (error) {
      throw ApiException.fromDio(error);
    } on FormatException catch (error) {
      throw ApiException(
        code: ApiErrorCode.unknown,
        message: '数据格式异常：${error.message}',
      );
    }
  }

  Future<List<ArticleCategory>> fetchCategories() async {
    try {
      return await _dataSource.fetchCategories();
    } on ApiException {
      rethrow;
    } on DioException catch (error) {
      throw ApiException.fromDio(error);
    } on FormatException catch (error) {
      throw ApiException(
        code: ApiErrorCode.unknown,
        message: '数据格式异常：${error.message}',
      );
    }
  }
}

/// 切换 Mock / 真接口的唯一开关。
final articleDataSourceProvider = Provider<ArticleDataSource>((ref) {
  if (AppConfig.useMock) {
    return MockArticleDataSource();
  }
  return RemoteArticleDataSource(ref.watch(dioProvider));
});

final articleRepositoryProvider = Provider<ArticleRepository>((ref) {
  return ArticleRepository(ref.watch(articleDataSourceProvider));
});