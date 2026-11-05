import '../../data/models/article.dart';
import 'article_favorite_data_source.dart';
import 'article_favorite_entry.dart';

/// 骨架期的假数据。
///
/// 三条分别为「有封面 / 无封面 / 无分类」，刻意覆盖列表里最容易塌的两种情形：
/// 封面缺失时占位图不能撑破行高，元信息缺失时不能渲染出空的分隔符。
///
/// `coverUrl` 一律给 `null`：测试环境不允许发网络请求，给假 URL 只会让
/// `CoverImage` 走失败分支、把版式验证变成错误态验证。真接口接上后封面自然会有。
class ArticleFavoriteMockDataSource implements ArticleFavoriteDataSource {
  const ArticleFavoriteMockDataSource();

  @override
  Future<List<ArticleFavoriteEntry>> fetchAll({required String userId}) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return [
      ArticleFavoriteEntry(
        article: const ArticleSummary(
          articleId: 'A-mock-1',
          title: '《街角魔族》新作动画制作决定，2027 年播出',
          summary: '制作阵容沿用前作，原作者绘制贺图公开。',
          category: '动画',
          sourceName: 'Mock 新闻',
          publishedAt: '2026-11-02T10:00:00Z',
        ),
        favoritedAt: DateTime.utc(2026, 11, 3, 9, 30),
      ),
      ArticleFavoriteEntry(
        article: const ArticleSummary(
          articleId: 'A-mock-2',
          title: '漫画《日常》连载再开，隔月刊恢复',
          summary: '作者休养结束后恢复连载，单行本第 12 卷同步发售。',
          category: '漫画',
          sourceName: 'Mock 新闻',
          publishedAt: '2026-10-28T04:15:00Z',
        ),
        favoritedAt: DateTime.utc(2026, 11, 1, 21, 5),
      ),
      ArticleFavoriteEntry(
        article: const ArticleSummary(
          articleId: 'A-mock-3',
          title: '轻小说新人奖结果公布，五部作品确定出版',
          sourceName: 'Mock 新闻',
        ),
      ),
    ];
  }
}
