import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/app.dart';
import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/core/storage/memory_work_cache.dart';
import 'package:otaku_app/core/storage/work_cache_provider.dart';
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

/// 记录收到的 tag 的数据源，同时按 tag 真实过滤——过滤逻辑放在这里才能证明
/// 「客户端发出的 tag 是对的」，只记录不过滤等于没验语义。
class _TagRecordingSource implements WorkDataSource {
  final List<String?> tags = <String?>[];

  /// 可过滤的数据集。标签刻意包含 `科幻` 与 `科幻机甲`，
  /// 用来验证契约要求的「精确匹配整个标签」。
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
    String? tag,
  }) async {
    tags.add(tag);
    final wanted = tag?.trim() ?? '';
    final items = catalog.where((w) {
      if (wanted.isEmpty) return true;
      final t = w.tags;
      return t != null && t.contains(wanted);
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

  group('契约：tag 的语义', () {
    test('精确匹配整个标签——「科幻」不命中「科幻机甲」', () async {
      final result = await buildRepository().fetchWorks(tag: '科幻');
      expect(result.value.items.map((w) => w.workId), ['W-sci']);
    });

    test('精确匹配另一个标签「科幻机甲」能命中', () async {
      final result = await buildRepository().fetchWorks(tag: '科幻机甲');
      expect(result.value.items.map((w) => w.workId), ['W-mecha']);
    });

    test('未知标签返空数组（不是错误）', () async {
      final result = await buildRepository().fetchWorks(tag: '不存在的标签');
      expect(result.value.items, isEmpty);
      // 契约：未知标签是 200 + 空数组，不是 404，所以这里不该抛。
      expect(result.fromCache, isFalse);
    });

    test('null 与空串都表示不过滤', () async {
      final repo = buildRepository();
      expect((await repo.fetchWorks()).value.items.length, 4);
      expect((await repo.fetchWorks(tag: '')).value.items.length, 4);
      expect((await repo.fetchWorks(tag: '   ')).value.items.length, 4);
    });

    test('tag 与 type / sort 可组合，且都原样发出去', () async {
      final repo = buildRepository();
      await repo.fetchWorks(type: WorkType.anime, sort: WorkSort.rating, tag: '科幻');
      expect(source.tags.last, '科幻');
    });
  });

  group('缓存键：标签必须是独立维度', () {
    test('按标签筛与不筛标签不共用缓存', () async {
      final repo = buildRepository();
      await repo.fetchWorks(tag: '科幻');

      source.tags.clear();
      final untagged = await repo.fetchWorks();
      // 不筛标签那次必须打到服务端（它没有独立的缓存条目）。
      expect(untagged.fromCache, isFalse);
      expect(untagged.value.items.length, 4);
    });

    test('离线时按标签取回的是该标签的那份，不是别的条件的', () async {
      final repo = buildRepository();
      await repo.fetchWorks(tag: '科幻');

      // 断网：仓储会回退缓存。
      final offline = _OfflineSource();
      final offlineRepo = WorkRepository(offline, cache: cache);
      final result = await offlineRepo.fetchWorks(tag: '科幻');

      expect(result.fromCache, isTrue);
      expect(result.value.items.map((w) => w.workId), ['W-sci']);
    });

    test('离线时请求未缓存过的标签，会报错而不是拿别的标签顶上', () async {
      final repo = buildRepository();
      await repo.fetchWorks(tag: '科幻');

      final offlineRepo = WorkRepository(_OfflineSource(), cache: cache);
      await expectLater(
        offlineRepo.fetchWorks(tag: '日常'),
        throwsA(anything),
        reason: '「日常」没缓存过，不能拿「科幻」的缓存顶上',
      );
    });
  });

  group('控制器：标签是筛选条件', () {
    test('selectTag 改变筛选状态，selectTag(null) 清除', () {
      final container = ProviderContainer(overrides: authOverrides());
      addTearDown(container.dispose);
      final controller = container.read(contentsFilterProvider.notifier);

      expect(container.read(contentsFilterProvider).tag, isNull);
      controller.selectTag('科幻');
      expect(container.read(contentsFilterProvider).tag, '科幻');
      controller.selectTag(null);
      expect(container.read(contentsFilterProvider).tag, isNull);
    });

    test('空串与空白等价于清除', () {
      final container = ProviderContainer(overrides: authOverrides());
      addTearDown(container.dispose);
      final controller = container.read(contentsFilterProvider.notifier);

      controller.selectTag('科幻');
      controller.selectTag('  ');
      expect(container.read(contentsFilterProvider).tag, isNull);
    });

    test('选标签不会丢掉已有的类型与排序', () {
      final container = ProviderContainer(overrides: authOverrides());
      addTearDown(container.dispose);
      final controller = container.read(contentsFilterProvider.notifier);

      controller.selectType(WorkType.anime);
      controller.selectSort(WorkSort.rating);
      controller.selectTag('科幻');

      final filter = container.read(contentsFilterProvider);
      expect(filter.type, WorkType.anime);
      expect(filter.sort, WorkSort.rating);
      expect(filter.tag, '科幻');
    });

    test('换类型 / 换排序 / 搜索都保留标签条件', () {
      final container = ProviderContainer(overrides: authOverrides());
      addTearDown(container.dispose);
      final controller = container.read(contentsFilterProvider.notifier);

      controller.selectTag('科幻');
      controller.selectType(WorkType.anime);
      controller.selectSort(WorkSort.year);
      controller.search('机动');

      final filter = container.read(contentsFilterProvider);
      expect(filter.tag, '科幻');
      expect(filter.type, WorkType.anime);
      expect(filter.sort, WorkSort.year);
      expect(filter.query, '机动');
    });

    test('相等性包含标签——否则 Riverpod 不会重建', () {
      const a = ContentsFilter(tag: '科幻');
      const b = ContentsFilter(tag: '科幻');
      const c = ContentsFilter(tag: '日常');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('界面：筛选状态可见', () {
    /// 自己持有容器：测试要从外面驱动筛选状态（模拟「点了某个标签」）。
    /// `ProviderScope.containerOf` 要的是子树里的 widget、不是 scope 本身，
    /// 所以这里用 [UncontrolledProviderScope]。
    ProviderContainer newContainer() {
      final container = ProviderContainer(
        overrides: [
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

    testWidgets('选中标签后显示筛选条与清除出口', (tester) async {
      final container = newContainer();
      await tester.pumpWidget(app(container));
      await tester.pumpAndSettle();

      // 直接驱动控制器：验卡片上点标签那条接线要等列表渲染出卡片，
      // 这里验的是筛选条本身在选中后确实出现。
      container.read(contentsFilterProvider.notifier).selectTag('科幻');
      await tester.pumpAndSettle();

      expect(find.text('标签：科幻'), findsOneWidget);
      expect(find.text('清除'), findsOneWidget);

      // 点「清除」应当真的把筛选撤掉——有入口还得能用。
      await tester.tap(find.text('清除'));
      await tester.pumpAndSettle();

      expect(find.textContaining('标签：'), findsNothing);
      expect(container.read(contentsFilterProvider).tag, isNull);
    });

    testWidgets('筛出 0 条时说清是筛选太窄，不是库里没数据', (
      tester,
    ) async {
      final container = newContainer();
      await tester.pumpWidget(app(container));
      await tester.pumpAndSettle();

      container.read(contentsFilterProvider.notifier).selectTag('不存在的标签');
      await tester.pumpAndSettle();

      // 契约里未知标签是 200 + 空数组，文案不能说成「这里还没有作品」——
      // 那会让用户以为同步任务没跑完。
      expect(find.text('没有这个标签的作品'), findsOneWidget);
      expect(find.text('这里还没有作品'), findsNothing);
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
    String? tag,
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