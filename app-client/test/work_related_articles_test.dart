import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:otaku_app/data/datasources/work_articles_data_source.dart';
import 'package:otaku_app/data/models/article.dart';
import 'package:otaku_app/data/models/paged_result.dart';
import 'package:otaku_app/features/article/article_card.dart';
import 'package:otaku_app/features/detail/work_related_articles_section.dart';

/// #410 作品详情页的「相关资讯」区块。
///
/// 只钉「用户看得见」的四态与跳转，不碰真接口：
/// 有数据渲染卡片、空/失败整块不显示、加载给占位、点卡片进资讯详情。
void main() {
  testWidgets('有关联资讯时显示标题与卡片', (tester) async {
    await tester.pumpWidget(_host(source: _FakeArticleDataSource()));
    await tester.pumpAndSettle();

    expect(find.text('相关资讯'), findsOneWidget);
    expect(find.byType(ArticleCard), findsNWidgets(2));
    expect(find.text('设定集发售'), findsOneWidget);
  });

  testWidgets('空结果整块不渲染，不显示「暂无」空态', (tester) async {
    await tester.pumpWidget(
      _host(source: _FakeArticleDataSource(result: _emptyPage())),
    );
    await tester.pumpAndSettle();

    expect(find.text('相关资讯'), findsNothing);
    expect(find.textContaining('暂无'), findsNothing);
    expect(find.byType(ArticleCard), findsNothing);
  });

  testWidgets('请求失败也不渲染，不把作品详情拖进错误态', (tester) async {
    await tester.pumpWidget(
      _host(source: _FakeArticleDataSource(fail: true)),
    );
    await tester.pumpAndSettle();

    expect(find.text('相关资讯'), findsNothing);
    expect(find.textContaining('失败'), findsNothing);
  });

  testWidgets('加载中给占位，不是突然顶出来', (tester) async {
    await tester.pumpWidget(
      _host(source: _FakeArticleDataSource(latency: const Duration(seconds: 2))),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('相关资讯'), findsNothing);
    await tester.pumpAndSettle(const Duration(seconds: 2));
  });

  testWidgets('点卡片跳到资讯详情', (tester) async {
    await tester.pumpWidget(_host(source: _FakeArticleDataSource()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('设定集发售'));
    await tester.pumpAndSettle();

    expect(find.text('详情页：A-001'), findsOneWidget);
  });

  testWidgets('还有下一页时如实说明没有显示全部', (tester) async {
    await tester.pumpWidget(
      _host(
        source: _FakeArticleDataSource(
          result: PagedResult<ArticleSummary>(
            items: <ArticleSummary>[_article('A-001', '设定集发售')],
            total: 26,
            page: 1,
            pageSize: 1,
            totalPages: 26,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('仅显示最近 1 条（共 26 条）'), findsOneWidget);
  });
}

PagedResult<ArticleSummary> _emptyPage() => PagedResult<ArticleSummary>(
  items: const <ArticleSummary>[],
  total: 0,
  page: 1,
  pageSize: 20,
  totalPages: 0,
);

ArticleSummary _article(String id, String title) =>
    ArticleSummary(articleId: id, title: title, category: '动画');

Widget _host({required _FakeArticleDataSource source}) {
  final container = ProviderContainer(
    overrides: [
      workArticlesDataSourceProvider.overrideWithValue(source),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      routerConfig: GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(
              body: SingleChildScrollView(
                child: WorkRelatedArticlesSection(workId: 'W-test'),
              ),
            ),
          ),
          GoRoute(
            path: '/articles/:articleId',
            builder: (context, state) => Scaffold(
              body: Text('详情页：${state.pathParameters['articleId']}'),
            ),
          ),
        ],
      ),
    ),
  );
}

class _FakeArticleDataSource implements WorkArticlesDataSource {
  _FakeArticleDataSource({
    PagedResult<ArticleSummary>? result,
    this.fail = false,
    this.latency = Duration.zero,
  }) : result = result ??
          PagedResult<ArticleSummary>(
            items: <ArticleSummary>[
              _article('A-001', '设定集发售'),
              _article('A-002', '声优访谈'),
            ],
            total: 2,
            page: 1,
            pageSize: 20,
            totalPages: 1,
          );

  final PagedResult<ArticleSummary> result;
  final bool fail;
  final Duration latency;

  @override
  Future<PagedResult<ArticleSummary>> fetch({
    required String workId,
    int page = 1,
    int pageSize = 20,
  }) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (fail) throw StateError('boom');
    return result;
  }
}
