import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/app.dart';
import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/core/router/app_router.dart';
import 'package:otaku_app/core/router/route_paths.dart';
import 'package:otaku_app/core/storage/memory_work_cache.dart';
import 'package:otaku_app/core/storage/work_cache.dart';
import 'package:otaku_app/core/storage/work_cache_provider.dart';
import 'package:otaku_app/core/util/tag_filter.dart';
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
import 'package:otaku_app/features/contents/contents_controller.dart';

import 'support/test_overrides.dart';

/// 记录收到的标签条件、并真实按 AND 过滤的数据源。
///
/// 过滤逻辑放在这里才能证明「客户端发出的条件是对的」——只记录不过滤等于没验语义。
class _TagRecordingSource implements WorkDataSource {
  final List<List<String>> calls = <List<String>>[];

  /// 标签刻意包含 `科幻` 与 `科幻机甲`，用来验证「整标签匹配」；
  /// `W-both` 同时带两个标签，用来验证 AND。
  static const List<WorkSummary> catalog = [
    WorkSummary(
      workId: 'W-sci',
      workType: WorkType.anime,
      title: '科幻作品',
      tags: ['科幻'],
    ),
    WorkSummary(
      workId: 'W-mecha',
      workType: WorkType.anime,
      title: '科幻机甲作品',
      tags: ['科幻机甲'],
    ),
    WorkSummary(
      workId: 'W-both',
      workType: WorkType.anime,
      title: '科幻日常两开花',
      tags: ['科幻', '日常'],
    ),
    WorkSummary(
      workId: 'W-slice',
      workType: WorkType.anime,
      title: '日常作品',
      tags: ['日常'],
    ),
    WorkSummary(
      workId: 'W-none',
      workType: WorkType.anime,
      title: '没有标签的作品',
    ),
  ];

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
    final wanted = normalizeTags(tags);
    calls.add(wanted);

    final items = catalog.where((work) {
      if (wanted.isEmpty) return true;
      final own = work.tags;
      if (own == null) return false;
      // AND：每个标签都要命中。
      return wanted.every(own.contains);
    }).toList(growable: false);

    return PagedResult<WorkSummary>(
      items: items,
      total: items.length,
      page: page,
      pageSize: pageSize,
      totalPages: items.isEmpty ? 0 : 1,
    );
  }

  @override
  Future<Work> fetchDetail(String workId) async =>
      Work(workId: workId, workType: WorkType.anime, title: workId);

  @override
  Future<RelatedWorks> fetchRelated(String workId, {int limit = 6}) async =>
      const RelatedWorks(basisTags: [], items: []);
}

void main() {
  late _TagRecordingSource source;
  late InMemoryWorkCache cache;

  setUp(() {
    source = _TagRecordingSource();
    cache = InMemoryWorkCache();
  });

  WorkRepository buildRepository() => WorkRepository(source, cache: cache);

  group('契约：标签的语义', () {
    test('整标签匹配——「科幻」不命中「科幻机甲」', () async {
      final result = await buildRepository().fetchWorks(tags: ['科幻']);
      expect(
        result.value.items.map((w) => w.workId),
        containsAll(<String>['W-sci', 'W-both']),
      );
      expect(result.value.items.map((w) => w.workId), isNot(contains('W-mecha')));
    });

    test('多标签是 AND：只有同时带这两个标签的才命中', () async {
      final result = await buildRepository().fetchWorks(
        tags: ['科幻', '日常'],
      );
      expect(result.value.items.map((w) => w.workId), ['W-both']);
    });

    test('未知标签返空数组（不是错误）', () async {
      final result = await buildRepository().fetchWorks(tags: ['不存在的标签']);
      expect(result.value.items, isEmpty);
      expect(result.fromCache, isFalse);
    });

    test('空列表表示不过滤', () async {
      final repo = buildRepository();
      expect((await repo.fetchWorks()).value.items.length, 5);
      expect((await repo.fetchWorks(tags: const [])).value.items.length, 5);
      // 全是空白的标签等于没给。
      expect((await repo.fetchWorks(tags: const ['  '])).value.items.length, 5);
    });

    test('去重：同一个标签选两次只算一个条件', () async {
      await buildRepository().fetchWorks(tags: ['科幻', ' 科幻 ']);
      expect(source.calls.last, ['科幻']);
    });

    test('上限 10 个：超出部分被截断，不是报错', () async {
      final many = List<String>.generate(12, (index) => 't$index');
      await buildRepository().fetchWorks(tags: many);
      expect(source.calls.last, hasLength(maxFilterTags));
    });
  });

  group('缓存键：标签是独立维度', () {
    test('按标签筛与不筛标签不共用缓存', () async {
      final repo = buildRepository();
      await repo.fetchWorks(tags: ['科幻']);

      final untagged = await repo.fetchWorks();
      // 不筛标签那次必须打到服务端（它没有独立的缓存条目）。
      expect(untagged.fromCache, isFalse);
      expect(untagged.value.items.length, 5);
    });

    test('选择顺序不影响缓存键——「科幻+日常」与「日常+科幻」是同一条', () {
      const a = ListCacheKey(
        type: null,
        query: '',
        sort: WorkSort.id,
        page: 1,
        tags: ['科幻', '日常'],
      );
      const b = ListCacheKey(
        type: null,
        query: '',
        sort: WorkSort.id,
        page: 1,
        tags: ['日常', '科幻'],
      );

      // 幂等：点选顺序不同不该各存一份缓存（也不该各打一次服务端）。
      expect(a, b);
      expect(a.storageKey, b.storageKey);
      expect(a.hashCode, b.hashCode);
    });

    test('离线时按标签取回的是该标签的那份', () async {
      final repo = buildRepository();
      await repo.fetchWorks(tags: ['科幻', '日常']);

      final offlineRepo = WorkRepository(_OfflineSource(), cache: cache);
      final result = await offlineRepo.fetchWorks(tags: ['日常', '科幻']);

      expect(result.fromCache, isTrue);
      expect(result.value.items.map((w) => w.workId), ['W-both']);
    });

    test('离线时请求没缓存过的标签组合，报错而不是拿别的顶上', () async {
      final repo = buildRepository();
      await repo.fetchWorks(tags: ['科幻']);

      final offlineRepo = WorkRepository(_OfflineSource(), cache: cache);
      await expectLater(
        offlineRepo.fetchWorks(tags: ['科幻', '日常']),
        throwsA(anything),
        reason: '两个标签的组合没缓存过，不能拿单标签的缓存顶上',
      );
    });
  });

  group('控制器：多标签是筛选条件', () {
    ProviderContainer newContainer() {
      final container = ProviderContainer(overrides: authOverrides());
      addTearDown(container.dispose);
      return container;
    }

    test('selectTags 整体替换；空列表清除', () {
      final container = newContainer();
      final controller = container.read(contentsFilterProvider.notifier);

      expect(container.read(contentsFilterProvider).tags, isEmpty);
      controller.selectTags(['科幻', '日常']);
      expect(container.read(contentsFilterProvider).tags, ['科幻', '日常']);
      controller.selectTags(const []);
      expect(container.read(contentsFilterProvider).tags, isEmpty);
    });

    test('toggleTag 加入 / 移出，且不动其它标签', () {
      final container = newContainer();
      final controller = container.read(contentsFilterProvider.notifier);

      controller.toggleTag('科幻');
      controller.toggleTag('日常');
      expect(container.read(contentsFilterProvider).tags, ['科幻', '日常']);

      controller.toggleTag('科幻');
      expect(container.read(contentsFilterProvider).tags, ['日常']);
    });

    test('到上限后 toggleTag 不再加新标签', () {
      final container = newContainer();
      final controller = container.read(contentsFilterProvider.notifier);

      controller.selectTags(List<String>.generate(maxFilterTags, (i) => 't$i'));
      controller.toggleTag('new');

      expect(
        container.read(contentsFilterProvider).tags,
        hasLength(maxFilterTags),
      );
      expect(container.read(contentsFilterProvider).tags, isNot(contains('new')));
    });

    test('换类型 / 换排序 / 搜索都保留标签条件', () {
      final container = newContainer();
      final controller = container.read(contentsFilterProvider.notifier);

      controller.selectTags(['科幻', '日常']);
      controller.selectType(WorkType.anime);
      controller.selectSort(WorkSort.year);
      controller.search('机动');

      final filter = container.read(contentsFilterProvider);
      expect(filter.tags, ['科幻', '日常']);
      expect(filter.type, WorkType.anime);
      expect(filter.sort, WorkSort.year);
      expect(filter.query, '机动');
    });

    test('相等性包含标签——否则 Riverpod 不会重建', () {
      const a = ContentsFilter(tags: ['科幻']);
      const b = ContentsFilter(tags: ['科幻']);
      const c = ContentsFilter(tags: ['日常']);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('界面：筛选状态可见', () {
    ProviderContainer newContainer() {
      final container = ProviderContainer(
        overrides: [
          appInitialLocationProvider.overrideWithValue(RoutePaths.contents),
          ...authOverrides(),
          workRepositoryProvider.overrideWithValue(buildRepository()),
          workCacheProvider.overrideWithValue(cache),
          collectionRepositoryProvider.overrideWithValue(
            _emptyCollectionRepository(),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    Widget app(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: const OtakuApp(),
    );

    testWidgets('未筛标签时不显示筛选条', (tester) async {
      await tester.pumpWidget(app(newContainer()));
      await tester.pumpAndSettle();

      expect(find.textContaining('标签：'), findsNothing);
    });

    testWidgets('选了多个标签：每个都能单独删掉', (tester) async {
      final container = newContainer();
      await tester.pumpWidget(app(container));
      await tester.pumpAndSettle();

      container.read(contentsFilterProvider.notifier).selectTags([
        '科幻',
        '日常',
      ]);
      await tester.pumpAndSettle();

      expect(find.text('标签：科幻'), findsOneWidget);
      expect(find.text('标签：日常'), findsOneWidget);

      await tester.tap(find.byTooltip('取消「科幻」'));
      await tester.pumpAndSettle();

      expect(find.text('标签：科幻'), findsNothing);
      expect(find.text('标签：日常'), findsOneWidget);
      expect(container.read(contentsFilterProvider).tags, ['日常']);
    });

    testWidgets('单标签筛出 0 条：说清是精确匹配，不是库里没数据', (tester) async {
      final container = newContainer();
      await tester.pumpWidget(app(container));
      await tester.pumpAndSettle();

      container.read(contentsFilterProvider.notifier).selectTag('不存在的标签');
      await tester.pumpAndSettle();

      expect(find.text('没有这个标签的作品'), findsOneWidget);
      expect(find.text('这里还没有作品'), findsNothing);
    });

    testWidgets('多标签筛出 0 条：文案解释「并且」关系', (tester) async {
      final container = newContainer();
      await tester.pumpWidget(app(container));
      await tester.pumpAndSettle();

      container.read(contentsFilterProvider.notifier).selectTags([
        '科幻机甲',
        '日常',
      ]);
      await tester.pumpAndSettle();

      expect(find.text('这几个标签没有同时命中的作品'), findsOneWidget);
    });
  });
}

/// 断网数据源：所有请求都抛网络错误，触发缓存回退。
class _OfflineSource implements WorkDataSource {
  @override
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    WorkSort sort = WorkSort.id,
    int page = 1,
    int pageSize = 20,
    List<String>? tags,
    int? year,
  }) async => throw _unreachable;

  @override
  Future<Work> fetchDetail(String workId) async => throw _unreachable;

  @override
  Future<RelatedWorks> fetchRelated(String workId, {int limit = 6}) async =>
      throw _unreachable;
}

/// 「后端不可达」——必须是真正的 [ApiException] 且 code 为 network：
/// 仓储只对 `network`/`timeout` 回退缓存，自造异常类型触发不了那条路径。
const ApiException _unreachable = ApiException(
  code: ApiErrorCode.network,
  message: '网络连接失败',
);

CollectionRepository _emptyCollectionRepository() =>
    CollectionRepository(_EmptyCollectionDataSource());

class _EmptyCollectionDataSource implements CollectionDataSource {
  @override
  Future<List<CollectionEntry>> fetchAll({CollectionStatus? status}) async =>
      const [];

  @override
  Future<CollectionState> fetchState(String workId) async =>
      CollectionState(workId: workId, collected: false);

  @override
  Future<CollectionState> add(String workId, {CollectionStatus? status}) async =>
      CollectionState(workId: workId, collected: true);

  @override
  Future<CollectionState> updateStatus(
    String workId,
    CollectionStatus? status,
  ) async {
    return CollectionState(workId: workId, collected: true);
  }

  @override
  Future<void> remove(String workId) async {}
}
