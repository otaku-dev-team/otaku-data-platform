import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../models/article.dart';
import '../models/paged_result.dart';
import 'article_data_source.dart';

/// 后端未就绪时的本地资讯数据源。数据来自 `assets/mock/articles_catalog.json`。
///
/// 刻意保留服务端的语义（分类过滤、分页、按发布时间倒序、404），
/// 这样切到真接口时页面行为不会突变。样本刻意覆盖三类：
/// 有原文链接的、没原文链接的、字段大面积缺失的。
class MockArticleDataSource implements ArticleDataSource {
  MockArticleDataSource({
    AssetBundle? bundle,
    this.latency = const Duration(milliseconds: 320),
  }) : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;

  /// 模拟网络耗时，用来验证加载态。测试里传 [Duration.zero]。
  final Duration latency;

  List<ArticleSummary>? _catalog;
  Map<String, ArticleDetail>? _details;

  static const String _catalogAsset = 'assets/mock/articles_catalog.json';

  Future<List<ArticleSummary>> _loadCatalog() async {
    final cached = _catalog;
    if (cached != null) return cached;

    final raw = await _bundle.loadString(_catalogAsset);
    final decoded = jsonDecode(raw);
    final items = decoded is List
        ? decoded
        : (decoded as Map<String, dynamic>)['items'] as List;
    _catalog = items
        .whereType<Map<String, dynamic>>()
        .map(ArticleSummary.fromJson)
        .toList(growable: false);
    return _catalog!;
  }

  @override
  Future<PagedResult<ArticleSummary>> fetchArticles({
    String? category,
    int page = 1,
    int pageSize = 20,
  }) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);

    final catalog = await _loadCatalog();
    final label = category?.trim() ?? '';
    // 排序必须在过滤之后、分页之前：分页切的是排序后的序列，
    // 否则「第二页」会把排序前的旧顺序混进来。
    final ordered = [...catalog]
      ..sort((a, b) {
        final at = a.publishedAt;
        final bt = b.publishedAt;
        // 没有发布时间的排最后：拿「无时间」和「有时间」比大小没有意义，
        // 但混在前面会让用户以为最新的是那几条。
        if (at == null && bt == null) return 0;
        if (at == null) return 1;
        if (bt == null) return -1;
        return bt.compareTo(at);
      });

    final filtered = label.isEmpty
        ? ordered
        : ordered.where((a) => a.category == label).toList(growable: false);

    final size = pageSize.clamp(1, AppConfig.maxPageSize);
    final total = filtered.length;
    final totalPages = total == 0 ? 0 : (total + size - 1) ~/ size;
    final start = (page - 1) * size;
    final items = start >= total
        ? const <ArticleSummary>[]
        : filtered.sublist(start, math.min(start + size, total));

    return PagedResult<ArticleSummary>(
      items: items,
      total: total,
      page: page,
      pageSize: size,
      totalPages: totalPages,
    );
  }

  @override
  Future<ArticleDetail> fetchDetail(String articleId) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);

    final cached = _details;
    if (cached != null) {
      final hit = cached[articleId];
      if (hit != null) return hit;
    }

    final catalog = await _loadCatalog();
    final target = catalog
        .where((a) => a.articleId == articleId)
        .cast<ArticleSummary?>()
        .firstWhere((_) => true, orElse: () => null);
    if (target == null) {
      // 与真接口一致：不存在就是 404，不是空详情。
      throw const ApiException(
        code: ApiErrorCode.articleNotFound,
        message: '资讯不存在',
      );
    }

    final details = <String, ArticleDetail>{};
    for (final item in catalog) {
      details[item.articleId] = ArticleDetail(
        articleId: item.articleId,
        title: item.title,
        summary: item.summary,
        body: item.summary,
        category: item.category,
        publishedAt: item.publishedAt,
        sourceName: item.sourceName,
        sourceUrl: item.sourceUrl,
        coverUrl: item.coverUrl,
        tags: item.tags,
        relatedWorkIds: const <String>[],
      );
    }
    _details = details;
    return details[articleId]!;
  }

  @override
  Future<List<ArticleCategory>> fetchCategories() async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);

    final catalog = await _loadCatalog();
    final counts = <String, int>{};
    for (final item in catalog) {
      final label = item.category;
      if (label == null) continue;
      counts[label] = (counts[label] ?? 0) + 1;
    }
    final result = counts.entries
        .map((e) => ArticleCategory(name: e.key, count: e.value))
        .toList()
      // 条数多的在前；条数一样时按名字排，保证顺序可预期（mock 若顺序抖动，
      // 分类 chips 会自己跳位置，看起来像 bug）。
      ..sort((a, b) {
        final byCount = b.count.compareTo(a.count);
        return byCount != 0 ? byCount : a.name.compareTo(b.name);
      });
    return result;
  }
}