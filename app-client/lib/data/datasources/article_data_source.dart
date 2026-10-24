import '../models/article.dart';
import '../models/paged_result.dart';

/// 资讯数据来源的抽象。真接口与 Mock 各实现一份，仓储层只认这个接口，
/// 联调时替换实现即可，页面代码一行都不用改。
abstract interface class ArticleDataSource {
  /// 一页资讯，按发布时间倒序（新的在前）。
  ///
  /// [category] 省略表示不过滤；未知分类返回空列表而不是报错
  /// （分类是数据里的值不是接口枚举）。
  Future<PagedResult<ArticleSummary>> fetchArticles({
    String? category,
    int page = 1,
    int pageSize = 20,
  });

  /// 详情。不存在时服务端返 404，页面据此显示「资讯不存在」。
  Future<ArticleDetail> fetchDetail(String articleId);

  /// 全部分类（条数多的在前）。空库返回空列表。
  Future<List<ArticleCategory>> fetchCategories();
}