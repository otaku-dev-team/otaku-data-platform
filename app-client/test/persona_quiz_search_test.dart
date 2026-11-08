import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:otaku_app/data/datasources/collection_data_source.dart';
import 'package:otaku_app/data/datasources/work_data_source.dart';
import 'package:otaku_app/data/models/collection_entry.dart';
import 'package:otaku_app/data/models/collection_state.dart';
import 'package:otaku_app/data/models/paged_result.dart';
import 'package:otaku_app/data/models/related_works.dart';
import 'package:otaku_app/data/models/work.dart';
import 'package:otaku_app/data/models/work_sort.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/data/repositories/collection_repository.dart';
import 'package:otaku_app/data/repositories/work_repository.dart';
import 'package:otaku_app/features/persona/persona_quiz_search_page.dart';

/// #505 全库搜索补标。
///
/// 钉两件事：**搜索词真的传下去了**（参数名写错会静默返回全部作品），
/// 以及**选了状态就真写收藏**（点了没反应比没有这个入口更糟）。
void main() {
  testWidgets('输入后去抖搜索，结果展示，参数是 query', (tester) async {
    final works = _FakeWorkDataSource(
      items: <WorkSummary>[_work('w-1', '银河边缘的旧书店')],
    );
    await tester.pumpWidget(_host(works: works));

    await tester.enterText(find.byType(TextField), '银河');
    // 去抖 350ms：立刻查会把每个字符都打一次接口。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(works.queries, <String>['银河']);
    expect(find.text('银河边缘的旧书店'), findsOneWidget);
  });

  testWidgets('选「看过」写 watched，行上回显已记', (tester) async {
    final works = _FakeWorkDataSource(
      items: <WorkSummary>[_work('w-1', '银河边缘的旧书店')],
    );
    final collection = _RecordingCollectionDataSource();
    await tester.pumpWidget(_host(works: works, collection: collection));

    await tester.enterText(find.byType(TextField), '银河');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('标记这部作品'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('看过').last);
    await tester.pumpAndSettle();

    expect(collection.added, hasLength(1));
    expect(collection.added.single.$1, 'w-1');
    expect(collection.added.single.$2, CollectionStatus.watched);
    // 回显让用户知道记上了，不用去收藏页确认。
    expect(find.textContaining('已记 · 看过'), findsOneWidget);
  });

  testWidgets('搜不到：给明确空态，不显示空列表', (tester) async {
    await tester.pumpWidget(_host(works: _FakeWorkDataSource(items: const [])));

    await tester.enterText(find.byType(TextField), '不存在的番');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.textContaining('没搜到'), findsOneWidget);
  });

  testWidgets('清空输入：结果清掉，回到提示态', (tester) async {
    final works = _FakeWorkDataSource(
      items: <WorkSummary>[_work('w-1', '银河边缘的旧书店')],
    );
    await tester.pumpWidget(_host(works: works));

    await tester.enterText(find.byType(TextField), '银河');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('银河边缘的旧书店'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();

    expect(find.text('银河边缘的旧书店'), findsNothing);
    expect(find.textContaining('搜一部作品'), findsOneWidget);
  });
}

Widget _host({
  required WorkDataSource works,
  CollectionDataSource? collection,
}) {
  final container = ProviderContainer(
    overrides: [
      workDataSourceProvider.overrideWithValue(works),
      collectionDataSourceProvider.overrideWithValue(
        collection ?? _RecordingCollectionDataSource(),
      ),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: PersonaQuizSearchPage()),
  );
}

WorkSummary _work(String id, String title) => WorkSummary(
  workId: id,
  workType: WorkType.anime,
  title: title,
  releaseYear: 2024,
);

class _FakeWorkDataSource implements WorkDataSource {
  _FakeWorkDataSource({required this.items});

  final List<WorkSummary> items;
  final List<String> queries = <String>[];

  @override
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    WorkSort sort = WorkSort.id,
    int page = 1,
    int pageSize = 20,
    List<String>? tags,
    int? year,
  }) async {
    if (query != null) queries.add(query);
    return PagedResult<WorkSummary>(
      items: items,
      total: items.length,
      page: 1,
      pageSize: pageSize,
      totalPages: 1,
    );
  }

  @override
  Future<Work> fetchDetail(String workId) => throw UnimplementedError();

  @override
  Future<RelatedWorks> fetchRelated(String workId, {int limit = 6}) =>
      throw UnimplementedError();
}

class _RecordingCollectionDataSource implements CollectionDataSource {
  final List<(String, CollectionStatus?)> added = <(String, CollectionStatus?)>[];

  @override
  Future<List<CollectionEntry>> fetchAll({CollectionStatus? status}) async =>
      const <CollectionEntry>[];

  @override
  Future<CollectionState> fetchState(String workId) async =>
      CollectionState(workId: workId, collected: false);

  @override
  Future<CollectionState> add(String workId, {CollectionStatus? status}) async {
    added.add((workId, status));
    return CollectionState(workId: workId, collected: true, status: status);
  }

  @override
  Future<CollectionState> updateStatus(
    String workId,
    CollectionStatus? status,
  ) async => CollectionState(workId: workId, collected: true, status: status);

  @override
  Future<void> remove(String workId) async {}
}
