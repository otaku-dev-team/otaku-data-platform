import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:otaku_app/data/datasources/work_data_source.dart';
import 'package:otaku_app/data/models/paged_result.dart';
import 'package:otaku_app/data/models/related_works.dart';
import 'package:otaku_app/data/models/source_rating.dart';
import 'package:otaku_app/data/models/work.dart';
import 'package:otaku_app/data/models/work_sort.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/data/repositories/work_repository.dart';
import 'package:otaku_app/features/contents/contents_controller.dart';
import 'package:otaku_app/features/contents/contents_page.dart';

import 'support/test_overrides.dart';

/// W1.5 D2：按评分排序时，「无评分条目沉底」这件事必须能被看出来。
///
/// 服务端是 `rating_value DESC`，NULL 自然排最后——问题不在排序，在于界面上
/// 末尾那一片卡片**没有评分徽标**，看着和「加载失败」一模一样。
class _FakeSource implements WorkDataSource {
  _FakeSource(this.items);

  final List<WorkSummary> items;

  @override
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    String? tag,
    WorkSort sort = WorkSort.id,
    int page = 1,
    int pageSize = 20,
  }) async {
    return PagedResult<WorkSummary>(
      items: items,
      total: items.length,
      page: 1,
      pageSize: pageSize,
      totalPages: 1,
    );
  }

  @override
  Future<Work> fetchDetail(String workId) async {
    throw StateError('这个用例不进详情');
  }

  @override
  Future<RelatedWorks> fetchRelated(String workId, {int limit = 6}) async =>
      const RelatedWorks(basisTags: <String>[], items: <WorkSummary>[]);
}

const _rated = WorkSummary(
  workId: 'W-1',
  workType: WorkType.anime,
  title: '有评分的作品',
  mainRating: SourceRating(value: 8.5, scale: '0-10', source: 'bangumi'),
);

const _unrated = WorkSummary(
  workId: 'W-2',
  workType: WorkType.anime,
  title: '没有评分的作品',
);

const _unrated2 = WorkSummary(
  workId: 'W-3',
  workType: WorkType.comic,
  title: '另一部没有评分的作品',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 用 [ProviderContainer] 而不是点菜单：排序控件是 PopupMenu，
  /// 手机窄宽度下菜单项会落到屏幕外（已记录在案，尚未定级），
  /// 测试里点它既不稳定也不代表真机行为。
  Future<ProviderContainer> pumpPage(
    WidgetTester tester,
    List<WorkSummary> items,
  ) async {
    final container = ProviderContainer(
      overrides: [
        workDataSourceProvider.overrideWithValue(_FakeSource(items)),
        ...authOverrides(),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ContentsPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return container;
  }

  testWidgets('默认排序：不标「暂无评分」，也不出现 0.0', (tester) async {
    await pumpPage(tester, const [_rated, _unrated, _unrated2]);

    // 契约 6.3：无评分整块不渲染，更不能显示 0.0。
    expect(find.text('暂无评分'), findsNothing);
    expect(find.text('0.0'), findsNothing);
    expect(find.text('没有评分的作品排在最后'), findsNothing);
    expect(find.text('有评分的作品'), findsOneWidget);
  });

  testWidgets('按评分排序：说明条 + 无评分条目逐个标出', (tester) async {
    final container = await pumpPage(
      tester,
      const [_rated, _unrated, _unrated2],
    );

    container.read(contentsFilterProvider.notifier).selectSort(WorkSort.rating);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('没有评分的作品排在最后'), findsOneWidget);
    expect(find.text('暂无评分'), findsNWidgets(2));
    // 有评分的那条照常显示分数，不能被标注覆盖掉。
    expect(find.text('8.5'), findsOneWidget);
    expect(find.text('0.0'), findsNothing);
  });

  testWidgets('按评分排序但结果全都有分：不显示说明条', (tester) async {
    final container = await pumpPage(tester, const [_rated, _rated]);

    container.read(contentsFilterProvider.notifier).selectSort(WorkSort.rating);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 全都有分的时候这一行是废话，还白占一屏高度。
    expect(find.text('没有评分的作品排在最后'), findsNothing);
    expect(find.text('暂无评分'), findsNothing);
  });
}
