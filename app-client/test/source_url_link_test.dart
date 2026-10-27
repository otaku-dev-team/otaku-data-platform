import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/data/repositories/collection_repository.dart';
import 'package:otaku_app/data/datasources/collection_mock_data_source.dart';
import 'package:otaku_app/data/datasources/work_data_source.dart';
import 'package:otaku_app/data/repositories/work_repository.dart';
import 'package:otaku_app/data/models/paged_result.dart';
import 'package:otaku_app/data/models/related_works.dart';
import 'package:otaku_app/data/models/work.dart';
import 'package:otaku_app/data/models/work_sort.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/features/detail/work_detail_page.dart';

import 'support/test_overrides.dart';

/// Issue #68：详情页「在来源站查看」回流入口。
///
/// 这里只验「该不该出现」和「地址能不能用」。真实打开浏览器无法在 widget 测试里验，
/// 需要真机/桌面手工确认（PR 里已注明）。
class _FakeWorkSource implements WorkDataSource {
  _FakeWorkSource(this.work);

  final Work work;

  @override
  Future<Work> fetchDetail(String workId) async => work;

  @override
  Future<RelatedWorks> fetchRelated(String workId, {int limit = 6}) async =>
      const RelatedWorks(basisTags: <String>[], items: <WorkSummary>[]);

  @override
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    WorkSort sort = WorkSort.id,
    int page = 1,
    int pageSize = 20,
    List<String>? tags,
  
    int? year,}) async => const PagedResult<WorkSummary>(
    items: [],
    total: 0,
    page: 1,
    pageSize: 20,
    totalPages: 0,
  );
}

Widget _app(Work work) => ProviderScope(
  overrides: [
    ...authOverrides(),
    workDataSourceProvider.overrideWithValue(_FakeWorkSource(work)),
    collectionDataSourceProvider.overrideWithValue(
      CollectionMockDataSource(delay: Duration.zero),
    ),
  ],
  child: MaterialApp(home: WorkDetailPage(workId: work.workId)),
);

Work _work({String? sourceUrl}) => Work(
  workId: 'W-1',
  workType: WorkType.anime,
  title: '街角魔族',
  releaseYear: 2022,
  source: 'otaku_site',
  sourceId: '476',
  sourceUrl: sourceUrl,
);

void main() {
  group('Work.parseSourceUrl', () {
    test('只放行 http / https', () {
      expect(
        Work.parseSourceUrl('https://154.8.194.198:8000/contents/476'),
        'https://154.8.194.198:8000/contents/476',
      );
      expect(
        Work.parseSourceUrl('http://154.8.194.198:8000/contents/476'),
        'http://154.8.194.198:8000/contents/476',
      );
    });

    test('其它协议一律丢弃', () {
      // 这个值最终交给系统浏览器，协议校验是最后一道闸。
      expect(Work.parseSourceUrl('javascript:alert(1)'), isNull);
      expect(Work.parseSourceUrl('file:///C:/Windows'), isNull);
      expect(Work.parseSourceUrl('intent://x'), isNull);
      expect(Work.parseSourceUrl('ftp://example.com/a'), isNull);
    });

    test('空值与无 host 一律返回 null', () {
      expect(Work.parseSourceUrl(null), isNull);
      expect(Work.parseSourceUrl(''), isNull);
      expect(Work.parseSourceUrl('   '), isNull);
      expect(Work.parseSourceUrl('https://'), isNull);
      expect(Work.parseSourceUrl(123), isNull);
    });

    test('前后空白会被去掉，不产生带空格的地址', () {
      expect(
        Work.parseSourceUrl('  https://example.com/a  '),
        'https://example.com/a',
      );
    });
  });

  group('详情页回流入口', () {
    testWidgets('有 source_url 时显示入口', (tester) async {
      await tester.pumpWidget(
        _app(_work(sourceUrl: 'https://154.8.194.198:8000/contents/476')),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('在来源站查看'), findsOneWidget);
    });

    testWidgets('source_url 为 null 时不显示入口（不是置灰）', (tester) async {
      await tester.pumpWidget(_app(_work()));
      await tester.pumpAndSettle();

      expect(find.byTooltip('在来源站查看'), findsNothing);
      expect(find.byIcon(Icons.open_in_new_rounded), findsNothing);
    });

    testWidgets('source_url 协议不可信时同样不显示', (tester) async {
      await tester.pumpWidget(_app(_work(sourceUrl: 'javascript:alert(1)')));
      await tester.pumpAndSettle();

      expect(find.byTooltip('在来源站查看'), findsNothing);
    });
  });
}
