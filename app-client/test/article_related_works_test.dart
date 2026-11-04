import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:otaku_app/data/datasources/article_data_source.dart';
import 'package:otaku_app/data/models/article.dart';
import 'package:otaku_app/data/models/paged_result.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/data/repositories/article_repository.dart';
import 'package:otaku_app/features/article/article_detail_page.dart';
import 'package:otaku_app/features/article/article_related_works_section.dart';
import 'package:otaku_app/shared/widgets/compact_work_card.dart';

/// 只给一条详情的内存数据源：整页用例要看的是区块有没有接上，不是列表行为。
class _OneDetailSource implements ArticleDataSource {
  _OneDetailSource(this.detail);

  final ArticleDetail detail;

  @override
  Future<PagedResult<ArticleSummary>> fetchArticles({
    String? category,
    int page = 1,
    int pageSize = 20,
  }) async =>
      const PagedResult<ArticleSummary>(
        items: <ArticleSummary>[],
        total: 0,
        page: 1,
        pageSize: 20,
        totalPages: 0,
      );

  @override
  Future<ArticleDetail> fetchDetail(String articleId) async => detail;

  @override
  Future<List<ArticleCategory>> fetchCategories() async =>
      const <ArticleCategory>[];
}

const _works = <WorkSummary>[
  WorkSummary(workId: 'W-a', workType: WorkType.anime, title: '关联作品甲'),
  WorkSummary(workId: 'W-b', workType: WorkType.comic, title: '关联作品乙'),
];

Map<String, dynamic> _detailJson() => <String, dynamic>{
  'article_id': 'A-1',
  'title': '标题',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ArticleDetail.related_works 解析', () {
    test('结构化列表解析成可用的本地作品', () {
      final detail = ArticleDetail.fromJson(<String, dynamic>{
        ..._detailJson(),
        'related_works': <Map<String, dynamic>>[
          <String, dynamic>{
            'work_id': 'W-a',
            'work_type': 'anime',
            'title': '甲',
          },
          <String, dynamic>{
            'work_id': 'W-b',
            'work_type': 'comic',
            'title': '乙',
            'cover_url': 'https://example.com/cover.jpg',
          },
        ],
      });

      expect(detail.relatedWorks?.map((e) => e.workId), <String>['W-a', 'W-b']);
      expect(detail.relatedWorks?[1].title, '乙');
      expect(detail.relatedWorks?[1].coverUrl, 'https://example.com/cover.jpg');
    });

    test('null / 空数组 / 非数组都归一成「不渲染」', () {
      for (final raw in <Object?>[null, <dynamic>[], 'oops', 3]) {
        final detail = ArticleDetail.fromJson(<String, dynamic>{
          ..._detailJson(),
          'related_works': raw,
        });
        expect(detail.relatedWorks, isNull, reason: 'raw=$raw');
      }
    });

    test('单条坏数据只跳过那一条，不拖垮整条资讯', () {
      final detail = ArticleDetail.fromJson(<String, dynamic>{
        ..._detailJson(),
        'related_works': <dynamic>[
          <String, dynamic>{'title': '缺 work_id'},
          <String, dynamic>{'work_id': '', 'title': '空 id'},
          123,
          <String, dynamic>{
            'work_id': 'W-ok',
            'work_type': 'game',
            'title': '完好的一条',
          },
        ],
      });

      expect(detail.relatedWorks, hasLength(1));
      expect(detail.relatedWorks?.single.workId, 'W-ok');
      expect(detail.title, '标题');
    });

    test('related_work_ids 是站点号，仍原样保留但不生成任何作品卡数据', () {
      final detail = ArticleDetail.fromJson(<String, dynamic>{
        ..._detailJson(),
        'related_work_ids': <String>['11972', '7534'],
      });

      expect(detail.relatedWorkIds, <String>['11972', '7534']);
      expect(detail.relatedWorks, isNull);
    });
  });

  testWidgets('有解析结果时渲染横滑卡，卡片用的是本地 work_id', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ArticleRelatedWorksSection(works: _works),
          ),
        ),
      ),
    );

    expect(find.text('关联作品'), findsOneWidget);
    expect(find.text('来源站标注的相关作品'), findsOneWidget);
    expect(find.byType(CompactWorkCard), findsNWidgets(2));
    expect(
      tester
          .widgetList<CompactWorkCard>(find.byType(CompactWorkCard))
          .map((e) => e.work.workId),
      <String>['W-a', 'W-b'],
    );

    // findsNWidgets 只证在树里，不证有尺寸：横滑条最容易静默画到容器外。
    final size = tester.getSize(find.byType(CompactWorkCard).first);
    expect(size.width, ArticleRelatedWorksSection.cardWidth);
    expect(size.height, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('null 与空数组都整块不渲染，不显示「暂无关联作品」', (tester) async {
    for (final works in <List<WorkSummary>?>[null, <WorkSummary>[]]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ArticleRelatedWorksSection(works: works),
            ),
          ),
        ),
      );
      expect(find.text('关联作品'), findsNothing);
      expect(find.byType(CompactWorkCard), findsNothing);
      expect(find.text('暂无关联作品'), findsNothing);
    }
  });

  testWidgets('详情页接上区块；后端未启用解析时页面照常显示', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Widget wrap(ArticleDetail detail) => ProviderScope(
      overrides: [
        articleRepositoryProvider.overrideWithValue(
          ArticleRepository(_OneDetailSource(detail)),
        ),
      ],
      child: MaterialApp(
        home: ArticleDetailPage(articleId: detail.articleId),
      ),
    );

    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    const withWorks = ArticleDetail(
      articleId: 'A-1',
      title: '有解析结果的资讯',
      body: '一段正文。',
      relatedWorkIds: <String>['11972'],
      relatedWorks: _works,
    );
    await tester.pumpWidget(wrap(withWorks));
    await settle();

    expect(find.text('一段正文。'), findsOneWidget);
    expect(find.text('关联作品'), findsOneWidget);
    expect(find.byType(CompactWorkCard), findsNWidgets(2));

    // 换 articleId 让 detail provider 重新查：#409 落地前后端不给这个字段，
    // 页面必须和以前一模一样，不出现空区块、不出现错误态。
    const withoutWorks = ArticleDetail(
      articleId: 'A-2',
      title: '还没有解析结果的资讯',
      body: '另一段正文。',
      relatedWorkIds: <String>['7534'],
    );
    await tester.pumpWidget(wrap(withoutWorks));
    await settle();

    expect(find.text('另一段正文。'), findsOneWidget);
    expect(find.text('关联作品'), findsNothing);
    expect(find.byType(CompactWorkCard), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
