import 'dart:math' as math;

import '../../data/models/article.dart';
import '../../data/models/paged_result.dart';
import 'article_favorite_data_source.dart';
import 'article_favorite_entry.dart';

/// 开发期的假数据（`USE_MOCK=true`，默认）。
///
/// 三条分别为「有封面 / 无封面 / 无分类」，刻意覆盖列表里最容易塌的两种情形：
/// 封面缺失时占位图不能撑破行高，元信息缺失时不能渲染出空的分隔符。
///
/// `coverUrl` 一律给 `null`：测试环境不允许发网络请求，给假 URL 只会让
/// `CoverImage` 走失败分支、把版式验证变成错误态验证。
///
/// **分页是真分页**（切片），不是「一次全给我」——否则控制器里的 `loadMore`
/// 在开发时永远走不到，等接真接口才发现分页逻辑没验证过。
class ArticleFavoriteMockDataSource implements ArticleFavoriteDataSource {
  ArticleFavoriteMockDataSource({this.delay = const Duration(milliseconds: 200)});

  final Duration delay;

  /// 被 `favorite()` 加进来、但列表里没有资讯本体的 id。
  ///
  /// mock 拿不到资讯详情，所以不往列表里塞；只保证「收藏后状态能查到」。
  final Set<String> _extraFavorited = <String>{};

  final List<ArticleFavoriteEntry> _items = <ArticleFavoriteEntry>[
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

  @override
  Future<PagedResult<ArticleFavoriteEntry>> fetchPage({
    int page = 1,
    int pageSize = 20,
  }) async {
    await Future<void>.delayed(delay);
    final start = (page - 1) * pageSize;
    final items = start >= _items.length
        ? const <ArticleFavoriteEntry>[]
        : _items.sublist(start, math.min(start + pageSize, _items.length));
    return PagedResult<ArticleFavoriteEntry>(
      items: items,
      total: _items.length,
      page: page,
      pageSize: pageSize,
      totalPages: _items.isEmpty ? 0 : ((_items.length - 1) ~/ pageSize) + 1,
    );
  }

  @override
  Future<bool> isFavorited(String articleId) async {
    await Future<void>.delayed(delay);
    return _extraFavorited.contains(articleId) ||
        _items.any((entry) => entry.article.articleId == articleId);
  }

  @override
  Future<void> favorite(String articleId) async {
    await Future<void>.delayed(delay);
    _extraFavorited.add(articleId);
  }

  @override
  Future<void> unfavorite(String articleId) async {
    await Future<void>.delayed(delay);
    _extraFavorited.remove(articleId);
    _items.removeWhere((entry) => entry.article.articleId == articleId);
  }
}
