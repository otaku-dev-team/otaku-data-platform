import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/data/datasources/article_data_source.dart';
import 'package:otaku_app/data/datasources/article_mock_data_source.dart';
import 'package:otaku_app/data/models/article.dart';
import 'package:otaku_app/data/models/paged_result.dart';
import 'package:otaku_app/data/repositories/article_repository.dart';
import 'package:otaku_app/features/article/article_card.dart';
import 'package:otaku_app/features/article/article_detail_page.dart';
import 'package:otaku_app/features/article/article_list_page.dart';
import 'package:otaku_app/features/article/article_meta_line.dart';

/// 内存数据源：不发网络、不读资源，widget 测试只看界面。
///
/// 过滤与分页语义照服务端实现（先筛后分页），这样「点分类」这条用例
/// 测的是页面联动，不是假数据刚好对上。
class _FakeArticleDataSource implements ArticleDataSource {
  _FakeArticleDataSource({
    required this.items,
    this.detail,
    this.categories = const [],
    this.failTimes = 0,
  });

  final List<ArticleSummary> items;
  final ArticleDetail? detail;
  final List<ArticleCategory> categories;

  /// 前 N 次列表请求抛网络错误，用来验「失败后有重试、重试后能恢复」。
  int failTimes;

  int listCalls = 0;
  String? lastCategory;

  @override
  Future<PagedResult<ArticleSummary>> fetchArticles({
    String? category,
    int page = 1,
    int pageSize = 20,
  }) async {
    listCalls++;
    lastCategory = category;
    if (listCalls <= failTimes) {
      throw const ApiException(
        code: ApiErrorCode.network,
        message: '网络连接失败',
      );
    }

    final label = category?.trim() ?? '';
    final filtered = label.isEmpty
        ? items
        : items.where((e) => e.category == label).toList(growable: false);
    final total = filtered.length;
    final totalPages = total == 0 ? 0 : (total + pageSize - 1) ~/ pageSize;
    final start = (page - 1) * pageSize;

    return PagedResult<ArticleSummary>(
      items: start >= total ? const [] : filtered.sublist(start, total),
      total: total,
      page: page,
      pageSize: pageSize,
      totalPages: totalPages,
    );
  }

  @override
  Future<ArticleDetail> fetchDetail(String articleId) async {
    final hit = detail;
    if (hit == null || hit.articleId != articleId) {
      throw const ApiException(
        code: ApiErrorCode.articleNotFound,
        message: '资讯不存在',
        statusCode: 404,
      );
    }
    return hit;
  }

  @override
  Future<List<ArticleCategory>> fetchCategories() async => categories;
}

const _withLink = ArticleSummary(
  articleId: 'A-1',
  title: '有原文链接的资讯',
  summary: '摘要一',
  category: '动画',
  publishedAt: '2026-10-21T10:00:00Z',
  sourceName: 'ACGCH',
  sourceUrl: 'https://example.com/news/1',
);

const _withoutLink = ArticleSummary(
  articleId: 'A-2',
  title: '没有原文链接的资讯',
  category: '漫画',
);

const _detail = ArticleDetail(
  articleId: 'A-1',
  title: '有原文链接的资讯',
  summary: '摘要一',
  body: '第一段。\n\n第二段。\n第三段。',
  category: '动画',
  publishedAt: '2026-10-21T10:00:00Z',
  sourceName: 'ACGCH',
  sourceUrl: 'https://example.com/news/1',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child, {ArticleDataSource? source}) {
    return ProviderScope(
      overrides: [
        articleRepositoryProvider.overrideWithValue(
          ArticleRepository(source ?? _FakeArticleDataSource(items: const [])),
        ),
      ],
      child: MaterialApp(home: child),
    );
  }

  /// 第一帧是骨架屏，异步结果要多走一帧才会落到界面上。
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  group('formatArticleDate', () {
    final now = DateTime(2026, 10, 22, 12, 0);

    // 用例里的时间统一写不带时区后缀的本地时间：带 `Z` 的话结果会跟着
    // 测试机的时区漂移（+8 与 -8 会差一天），跟「按日历天比较」这条无关。
    test('今天与昨天按日历天算，不按 24 小时', () {
      // 昨晚 23:50 的消息，今天中午看仍然是「昨天」。
      expect(formatArticleDate('2026-10-21T23:50:00', now: now), '昨天');
      expect(formatArticleDate('2026-10-22T00:10:00', now: now), '今天');
    });

    test('同年只写月日，跨年补年份', () {
      expect(formatArticleDate('2026-01-05T12:00:00', now: now), '1月5日');
      expect(formatArticleDate('2025-12-31T12:00:00', now: now), '2025-12-31');
    });

    test('空值与非法值返回 null，不编造时间', () {
      expect(formatArticleDate(null, now: now), isNull);
      expect(formatArticleDate('', now: now), isNull);
      expect(formatArticleDate('not-a-date', now: now), isNull);
    });
  });

  group('ArticleSummary / ArticleDetail 解析', () {
    test('空串字段一律当缺失，不是空文本', () {
      final summary = ArticleSummary.fromJson(const {
        'article_id': 'A-1',
        'title': '标题',
        'summary': '   ',
        'category': '',
        'source_url': '',
        'tags': [],
      });
      expect(summary.summary, isNull);
      expect(summary.category, isNull);
      expect(summary.sourceUrl, isNull);
      expect(summary.tags, isNull);
    });

    test('缺 article_id 或 title 直接抛 FormatException', () {
      expect(
        () => ArticleSummary.fromJson(const {'title': '标题'}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ArticleSummary.fromJson(const {'article_id': 'A-1'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('正文一行一段，空行不产生空段落', () {
      expect(_detail.paragraphs, ['第一段。', '第二段。', '第三段。']);
      expect(
        const ArticleDetail(articleId: 'A-1', title: 't', body: '  \n \n')
            .paragraphs,
        isEmpty,
      );
    });
  });

  test('ARTICLE_NOT_FOUND 单独成码，文案与作品区分开', () {
    expect(
      ApiErrorCode.fromWire('ARTICLE_NOT_FOUND'),
      ApiErrorCode.articleNotFound,
    );
    final notFound = const ApiException(
      code: ApiErrorCode.articleNotFound,
      message: '资讯不存在',
    );
    expect(notFound.isNotFound, isTrue);
    expect(notFound.userMessage, '资讯不存在');
  });

  group('MockArticleDataSource', () {
    test('分类聚合按条数降序，详情不存在抛 ARTICLE_NOT_FOUND', () async {
      final source = MockArticleDataSource(latency: Duration.zero);
      final categories = await source.fetchCategories();
      expect(categories.map((e) => e.name), isNotEmpty);
      for (var i = 1; i < categories.length; i++) {
        expect(categories[i - 1].count, greaterThanOrEqualTo(categories[i].count));
      }

      await expectLater(
        source.fetchDetail('A-not-exist'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            ApiErrorCode.articleNotFound,
          ),
        ),
      );
    });

    test('按分类过滤与分页', () async {
      final source = MockArticleDataSource(latency: Duration.zero);
      final all = await source.fetchArticles(pageSize: 2);
      expect(all.total, 5);
      expect(all.items, hasLength(2));
      expect(all.totalPages, 3);

      final filtered = await source.fetchArticles(category: '动画');
      expect(filtered.total, 1);
      expect(filtered.items.single.articleId, 'A-mock0003');
    });
  });

  testWidgets('列表页按条渲染，只有带原文链接的卡片给跳转入口', (tester) async {
    await tester.pumpWidget(
      wrap(
        const ArticleListPage(),
        source: _FakeArticleDataSource(
          items: const [_withLink, _withoutLink],
          categories: const [
            ArticleCategory(name: '动画', count: 1),
            ArticleCategory(name: '漫画', count: 1),
          ],
        ),
      ),
    );
    await settle(tester);

    expect(find.text('最新资讯'), findsOneWidget);
    expect(find.byType(ArticleCard), findsNWidgets(2));
    // 章程 G3：有原文就给入口，没有就整块不渲染（不是一个点不动的按钮）。
    expect(find.text('在来源站查看'), findsOneWidget);

    // 只有第一条走头条版式：一屏之内先给一条重点，其余按时间排。
    // 版式是 ArticleCard 的一个开关，条数与可点区域都不变。
    final cards = tester.widgetList<ArticleCard>(find.byType(ArticleCard)).toList();
    expect(cards[0].featured, isTrue);
    expect(cards[1].featured, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点分类后按该分类重查，结果跟着变', (tester) async {
    final source = _FakeArticleDataSource(
      items: const [_withLink, _withoutLink],
      categories: const [
        ArticleCategory(name: '动画', count: 1),
        ArticleCategory(name: '漫画', count: 1),
      ],
    );
    await tester.pumpWidget(wrap(const ArticleListPage(), source: source));
    await settle(tester);
    expect(find.byType(ArticleCard), findsNWidgets(2));

    // 卡片元信息行里也有「漫画」两个字的分类，按文本找会命中两个：
    // 明确点 chip 本身。
    await tester.tap(find.widgetWithText(ChoiceChip, '漫画'));
    await settle(tester);

    expect(source.lastCategory, '漫画');
    expect(find.byType(ArticleCard), findsOneWidget);
    expect(find.text('没有原文链接的资讯'), findsOneWidget);
  });

  testWidgets('空列表给空状态，不是空白页', (tester) async {
    await tester.pumpWidget(
      wrap(const ArticleListPage(), source: _FakeArticleDataSource(items: const [])),
    );
    await settle(tester);

    expect(find.text('还没有资讯'), findsOneWidget);
    expect(find.byType(ArticleCard), findsNothing);
  });

  testWidgets('首屏失败给重试，重试后能恢复', (tester) async {
    final source = _FakeArticleDataSource(
      items: const [_withLink],
      failTimes: 1,
    );
    await tester.pumpWidget(wrap(const ArticleListPage(), source: source));
    await settle(tester);

    expect(find.byType(ArticleCard), findsNothing);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await settle(tester);

    expect(find.byType(ArticleCard), findsOneWidget);
  });

  testWidgets('详情 404 提示资讯不存在，且不给重试按钮', (tester) async {
    await tester.pumpWidget(
      wrap(
        const ArticleDetailPage(articleId: 'A-404'),
        source: _FakeArticleDataSource(items: const [], detail: _detail),
      ),
    );
    await settle(tester);

    expect(find.text('资讯不存在'), findsOneWidget);
    expect(find.text('返回列表'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('详情渲染分段正文与原文入口', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      wrap(
        const ArticleDetailPage(articleId: 'A-1'),
        source: _FakeArticleDataSource(items: const [], detail: _detail),
      ),
    );
    await settle(tester);

    expect(find.text('第一段。'), findsOneWidget);
    expect(find.text('第三段。'), findsOneWidget);
    expect(find.byTooltip('在来源站查看'), findsOneWidget);
  });

  testWidgets('抓不到正文时不给空白页，提示去来源站看', (tester) async {
    const noBody = ArticleDetail(
      articleId: 'A-3',
      title: '只有标题的资讯',
      sourceUrl: 'https://example.com/news/3',
    );
    await tester.pumpWidget(
      wrap(
        const ArticleDetailPage(articleId: 'A-3'),
        source: _FakeArticleDataSource(items: const [], detail: noBody),
      ),
    );
    await settle(tester);

    expect(find.text('只有标题的资讯'), findsOneWidget);
    expect(find.text('这条资讯没有正文，可以去来源站看原文'), findsOneWidget);
    expect(find.byTooltip('在来源站查看'), findsOneWidget);
  });
}
