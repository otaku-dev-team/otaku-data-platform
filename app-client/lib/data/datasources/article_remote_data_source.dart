import 'package:dio/dio.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../models/article.dart';
import '../models/paged_result.dart';
import 'article_data_source.dart';

/// 资讯的真实接口实现（契约路径以 Java 最终定义为准）。
class RemoteArticleDataSource implements ArticleDataSource {
  RemoteArticleDataSource(this._dio);

  final Dio _dio;

  static const String _listPath = '/api/articles';
  static const String _categoriesPath = '/api/articles/categories';
  static String _detailPath(String articleId) =>
      '/api/articles/${Uri.encodeComponent(articleId)}';

  @override
  Future<PagedResult<ArticleSummary>> fetchArticles({
    String? category,
    int page = 1,
    int pageSize = AppConfig.pageSize,
  }) async {
    final label = category?.trim() ?? '';
    final response = await _dio.get<Map<String, dynamic>>(
      _listPath,
      queryParameters: <String, dynamic>{
        // 分类是数据里的值不是接口枚举：未知分类服务端返 200 + 空列表，
        // 所以这里不做本地校验，传什么查什么。
        if (label.isNotEmpty) 'category': label,
        'page': page,
        // 契约：上限 50，超了服务端截断，这里只防呆。
        'page_size': pageSize.clamp(1, AppConfig.maxPageSize),
      },
    );
    final data = response.data;
    if (data == null) {
      throw const ApiException(
        code: ApiErrorCode.unknown,
        message: '服务端返回了空响应',
      );
    }
    return PagedResult<ArticleSummary>.fromJson(
      data,
      ArticleSummary.fromJson,
    );
  }

  @override
  Future<ArticleDetail> fetchDetail(String articleId) async {
    final response = await _dio.get<Map<String, dynamic>>(
      _detailPath(articleId),
    );
    final data = response.data;
    if (data == null) {
      throw const ApiException(
        code: ApiErrorCode.unknown,
        message: '服务端返回了空响应',
      );
    }
    return ArticleDetail.fromJson(data);
  }

  @override
  Future<List<ArticleCategory>> fetchCategories() async {
    final response = await _dio.get<List<dynamic>>(_categoriesPath);
    final data = response.data;
    if (data == null) {
      throw const ApiException(
        code: ApiErrorCode.unknown,
        message: '服务端返回了空响应',
      );
    }
    return data
        .whereType<Map<String, dynamic>>()
        .map(ArticleCategory.fromJson)
        .toList(growable: false);
  }
}