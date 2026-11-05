import '../../data/models/article.dart';

/// 一条「我收藏的资讯」。
///
/// **接口尚未定稿**（#377 只拍了方案：独立表 + `/api/me/article-favorites`），
/// 所以这里只放页面真正需要的两样：资讯本体与收藏时间。
///
/// 为什么复用 [ArticleSummary] 而不是另造一套字段：它是契约里已注册的形状，
/// 资讯列表与详情都在用；收藏列表多出来的只有「什么时候收的」。
/// 将来若契约给的是扁平字段（`article_title` 之类），只改数据源里的映射，
/// 页面与组件一行不用动——这正是把它包一层、而不是让页面直接吃 JSON 的原因。
class ArticleFavoriteEntry {
  const ArticleFavoriteEntry({required this.article, this.favoritedAt});

  final ArticleSummary article;

  /// `null` = 服务端没给（不是「刚收藏」）。
  final DateTime? favoritedAt;
}
