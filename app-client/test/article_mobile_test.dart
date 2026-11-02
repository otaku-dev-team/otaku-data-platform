import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/core/platform_info.dart';
import 'package:otaku_app/core/theme/app_theme.dart';
import 'package:otaku_app/data/datasources/article_data_source.dart';
import 'package:otaku_app/data/models/article.dart';
import 'package:otaku_app/data/models/paged_result.dart';
import 'package:otaku_app/data/repositories/article_repository.dart';
import 'package:otaku_app/features/article/article_detail_page.dart';
import 'package:otaku_app/features/article/article_list_page.dart';

import 'support/test_overrides.dart';

const _longCategory = '这个分类名称非常长也应完整显示并可选择';
const _articleTitle = '测试资讯标题';
const _bodyText = '正文可以长按选择文字，并复制需要的内容。';

class _ArticleSource implements ArticleDataSource {
  int listCalls = 0;
  String? lastCategory;
  bool empty = false;
  List<ArticleCategory> categories = const [
    ArticleCategory(name: '动画', count: 1),
    ArticleCategory(name: _longCategory, count: 0),
  ];

  @override
  Future<PagedResult<ArticleSummary>> fetchArticles({
    String? category,
    int page = 1,
    int pageSize = 20,
  }) async {
    listCalls++;
    lastCategory = category;
    final items = empty || category == _longCategory
        ? const <ArticleSummary>[]
        : const [
            ArticleSummary(
              articleId: 'A-1',
              title: _articleTitle,
              category: '动画',
            ),
          ];
    return PagedResult(
      items: items,
      total: items.length,
      page: page,
      pageSize: pageSize,
      totalPages: items.isEmpty ? 0 : 1,
    );
  }

  @override
  Future<List<ArticleCategory>> fetchCategories() async => categories;

  @override
  Future<ArticleDetail> fetchDetail(String articleId) async =>
      const ArticleDetail(
        articleId: 'A-1',
        title: '手机上的长资讯标题应当自然换行并保持清晰可读',
        body: _bodyText,
        summary: '这是摘要，正文位于下方。',
        category: _longCategory,
        sourceName: '很长的资讯网站名称也能完整阅读',
        publishedAt: '2026-01-01T12:00:00',
        sourceUrl: 'https://example.com/article/1',
      );
}

void main() {
  Future<void> pumpPage(
    WidgetTester tester,
    _ArticleSource source, {
    Widget page = const ArticleListPage(),
    double width = 390,
    double scale = 1,
  }) async {
    PlatformInfo.desktopOverride = false;
    addTearDown(PlatformInfo.resetOverride);
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...authOverrides(),
          articleRepositoryProvider.overrideWithValue(
            ArticleRepository(source),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: page,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('320宽双倍字号可展开全部分类，空分类可直接回全部资讯', (tester) async {
    final source = _ArticleSource();
    await pumpPage(tester, source, width: 320, scale: 2);
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(OutlinedButton, '全部资讯'));
    await tester.pumpAndSettle();
    expect(find.text('资讯分类'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, _longCategory));
    await tester.pumpAndSettle();
    expect(source.lastCategory, _longCategory);
    expect(find.text('这个分类下暂时没有资讯'), findsOneWidget);
    expect(find.text(_longCategory), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('查看全部资讯'));
    await tester.tap(find.text('查看全部资讯'));
    await tester.pumpAndSettle();
    expect(source.lastCategory, isNull);
    expect(find.text(_articleTitle), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭分类面板不会更改当前分类', (tester) async {
    final source = _ArticleSource();
    await pumpPage(tester, source);
    final calls = source.listCalls;
    await tester.tap(find.widgetWithText(OutlinedButton, '全部资讯'));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(BottomSheet)).height,
      lessThan(844 * 0.6),
    );
    await tester.tap(find.byTooltip('关闭分类'));
    await tester.pumpAndSettle();
    expect(source.listCalls, calls);
    expect(source.lastCategory, isNull);
  });

  testWidgets('分类较多时面板可滚动到最后一项并选择', (tester) async {
    final source = _ArticleSource()
      ..categories = List.generate(
        20,
        (index) => ArticleCategory(name: '分类 $index', count: 1),
      );
    await pumpPage(tester, source, width: 320, scale: 2);
    await tester.tap(find.widgetWithText(OutlinedButton, '全部资讯'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.widgetWithText(ListTile, '分类 19'),
      250,
      scrollable: find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.widgetWithText(ListTile, '分类 19'));
    await tester.pumpAndSettle();
    expect(source.lastCategory, '分类 19');
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final empty in [false, true]) {
    testWidgets('${empty ? '空' : '单条'}资讯列表可以下拉刷新', (tester) async {
      final source = _ArticleSource()..empty = empty;
      await pumpPage(tester, source);
      final calls = source.listCalls;
      await tester.drag(find.byType(ListView).first, const Offset(0, 350));
      await tester.pumpAndSettle();
      expect(source.listCalls, greaterThan(calls));
    });
  }

  testWidgets('320宽双倍字号详情元信息完整换行，正文处于可选择区域', (tester) async {
    await pumpPage(
      tester,
      _ArticleSource(),
      page: const ArticleDetailPage(articleId: 'A-1'),
      width: 320,
      scale: 2,
    );
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text(_bodyText),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.ancestor(
        of: find.text(_bodyText),
        matching: find.byType(SelectionArea),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.longPress(find.text(_bodyText));
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
