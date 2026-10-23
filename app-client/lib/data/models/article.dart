import 'package:flutter/foundation.dart';

import 'paged_result.dart';

/// 资讯的列表项与详情。
///
/// **列表项不带 `body`**：正文可能几百 KB，一页 20 条就是几 MB，
/// 而列表页根本不显示正文。后端也是这么切的（见 ArticleDtos）——
/// 客户端不该在列表接口上浪费带宽去拿用不到的东西。
@immutable
class ArticleSummary {
  const ArticleSummary({
    required this.articleId,
    required this.title,
    this.summary,
    this.category,
    this.publishedAt,
    this.sourceName,
    this.sourceUrl,
    this.coverUrl,
    this.tags,
  });

  /// 不透明字符串：不解析结构、不做数值比较。
  final String articleId;

  final String title;

  /// `null` 与空串在界面上同义：都不渲染摘要。
  final String? summary;

  /// 分类徽章原文，如「漫画」「动画」。`null` 表示来源未提供。
  final String? category;

  /// ISO-8601 发布时间。`null` 时**不渲染时间**——
  /// 编一个「今天」出来比不显示更糟，用户会以为是很新的消息。
  final String? publishedAt;

  /// 来源站点名，如「ラノベニュースオンライン」。
  final String? sourceName;

  /// **原文链接**（来源站自己的外部地址），对应项目章程 G3
  /// 「用户不被困在平台内」。为 `null` 时界面不给跳转入口。
  ///
  /// 注意与「资讯在本站的地址」区分：后者是 `/articles/{id}` 路由，
  /// 这个是来源站原文，两者用途完全不同。
  final String? sourceUrl;

  final String? coverUrl;

  /// `null` 与 `[]` 同义：不渲染标签区。
  final List<String>? tags;

  factory ArticleSummary.fromJson(Map<String, dynamic> json) {
    final articleId = json['article_id'];
    final title = json['title'];
    if (articleId is! String || articleId.isEmpty) {
      throw const FormatException('article_id 缺失或为空');
    }
    if (title is! String || title.isEmpty) {
      throw const FormatException('title 缺失或为空');
    }
    final coverUrl = json['cover_url'];
    return ArticleSummary(
      articleId: articleId,
      title: title,
      summary: _nonEmpty(json['summary']),
      category: _nonEmpty(json['category']),
      publishedAt: _nonEmpty(json['published_at']),
      sourceName: _nonEmpty(json['source_name']),
      sourceUrl: _nonEmpty(json['source_url']),
      coverUrl: coverUrl is String && coverUrl.isNotEmpty ? coverUrl : null,
      tags: _stringList(json['tags']),
    );
  }

  @override
  String toString() => 'ArticleSummary($articleId, $title)';
}

/// 资讯详情。比列表多 [ArticleDetail.body]。
@immutable
class ArticleDetail {
  const ArticleDetail({
    required this.articleId,
    required this.title,
    this.summary,
    this.body,
    this.category,
    this.publishedAt,
    this.sourceName,
    this.sourceUrl,
    this.coverUrl,
    this.tags,
    this.relatedWorkIds,
  });

  final String articleId;
  final String title;
  final String? summary;

  /// 正文纯文本，**一行一段**（服务端归一过）。`null` 表示这条资讯
  /// 没抓到正文——照样展示标题与摘要，不给空白页。
  final String? body;

  final String? category;
  final String? publishedAt;
  final String? sourceName;
  final String? sourceUrl;
  final String? coverUrl;
  final List<String>? tags;

  /// 来源站给的关联作品 id 原文。
  ///
  /// **客户端不用它跳本地详情**：那些是编辑推荐的周边作品，不是本文主角，
  /// 拿来跳转会给出「这篇文章讲的就是这部作品」的错误结论。
  /// 留着是为了将来做关联时不必重新抓页面。
  final List<String>? relatedWorkIds;

  factory ArticleDetail.fromJson(Map<String, dynamic> json) {
    final articleId = json['article_id'];
    final title = json['title'];
    if (articleId is! String || articleId.isEmpty) {
      throw const FormatException('article_id 缺失或为空');
    }
    if (title is! String || title.isEmpty) {
      throw const FormatException('title 缺失或为空');
    }
    final coverUrl = json['cover_url'];
    return ArticleDetail(
      articleId: articleId,
      title: title,
      summary: _nonEmpty(json['summary']),
      body: _nonEmpty(json['body']),
      category: _nonEmpty(json['category']),
      publishedAt: _nonEmpty(json['published_at']),
      sourceName: _nonEmpty(json['source_name']),
      sourceUrl: _nonEmpty(json['source_url']),
      coverUrl: coverUrl is String && coverUrl.isNotEmpty ? coverUrl : null,
      tags: _stringList(json['tags']),
      relatedWorkIds: _stringList(json['related_work_ids']),
    );
  }

  /// 正文按行拆成段落。服务端已归一成「一行一段」，
  /// 这里直接拆即可——不需要也不该在客户端猜分段规则。
  List<String> get paragraphs {
    final raw = body;
    if (raw == null || raw.isEmpty) return const [];
    return raw
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
  }
}

/// 一页资讯。后端形状与作品列表一致，用同一个 [PagedResult]。
typedef ArticlePage = PagedResult<ArticleSummary>;

/// 分类筛选项（附条数）。
@immutable
class ArticleCategory {
  const ArticleCategory({required this.name, required this.count});

  final String name;
  final int count;

  factory ArticleCategory.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String || name.isEmpty) {
      throw const FormatException('分类 name 缺失或为空');
    }
    final count = json['count'];
    return ArticleCategory(
      name: name,
      count: count is num ? count.toInt() : 0,
    );
  }
}

String? _nonEmpty(Object? raw) {
  if (raw is! String) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

List<String>? _stringList(Object? raw) {
  if (raw is! List) return null;
  final values = raw
      .whereType<String>()
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList(growable: false);
  return values.isEmpty ? null : values;
}