import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/app.dart';
import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/core/storage/memory_work_cache.dart';
import 'package:otaku_app/data/datasources/work_data_source.dart';
import 'package:otaku_app/data/datasources/collection_data_source.dart';
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
import 'package:otaku_app/core/router/app_router.dart';
import 'package:otaku_app/core/router/route_paths.dart';

import 'support/test_overrides.dart';

/// 可控的数据源：在「在线」与「离线」之间切换，并记录请求。
class _SwitchableWorkSource implements WorkDataSource {
  _SwitchableWorkSource();

  /// 置为 true 时所有请求都抛「网络不可达」。
  bool offline = false;

  /// 置为 true 时所有请求都抛 404。
  bool notFound = false;

  int listCalls = 0;
  int detailCalls = 0;

  static const WorkSummary _item = WorkSummary(
    workId: 'W-1',
    workType: WorkType.anime,
    title: '缓存里的作品',
    releaseYear: 2020,
  );

  @override
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    WorkSort sort = WorkSort.id,
    int page = 1,
    int pageSize = 20,
    String? tag,
  }) async {
    listCalls++;
    if (notFound) {
      throw const ApiException(
        code: ApiErrorCode.workNotFound,
        message: '作品不存在',
        statusCode: 404,
      );
    }
    if (offline) {
      throw const ApiException(
        code: ApiErrorCode.network,
        message: '网络连接失败',
      );
    }
    return PagedResult<WorkSummary>(
      items: const [_item],
      total: 1,
      page: page,
      pageSize: pageSize,
      totalPages: 1,
    );
  }

  @override
  Future<Work> fetchDetail(String workId) async {
    detailCalls++;
    if (notFound) {
      throw const ApiException(
        code: ApiErrorCode.workNotFound,
        message: '作品不存在',
        statusCode: 404,
      );
    }
    if (offline) {
      throw const ApiException(
        code: ApiErrorCode.network,
        message: '网络连接失败',
      );
    }
    return const Work(
      workId: 'W-1',
      workType: WorkType.anime,
      title: '缓存里的作品',
      summary: '简介',
      releaseYear: 2020,
    );
  }

  @override
  Future<RelatedWorks> fetchRelated(String workId, {int limit = 6}) async {
    if (offline) {
      throw const ApiException(
        code: ApiErrorCode.network,
        message: '网络连接失败',
      );
    }
    return const RelatedWorks(basisTags: ['科幻'], items: [_item]);
  }
}

/// W1.2 离线可用的验收测试。对应 `docs/client-enhancement-plan.md` 的 B1–B5。
void main() {
  late _SwitchableWorkSource source;
  late InMemoryWorkCache cache;
  late WorkRepository repository;

  setUp(() {
    source = _SwitchableWorkSource();
    cache = InMemoryWorkCache();
    repository = WorkRepository(source, cache: cache);
  });

  group('B1 断网后仍能看已浏览内容', () {
    test('在线取到列表后断网，同样条件下能回退到缓存', () async {
      final online = await repository.fetchWorks();
      expect(online.fromCache, isFalse);

      source.offline = true;
      final offline = await repository.fetchWorks();

      expect(offline.fromCache, isTrue);
      expect(offline.value.items.first.title, '缓存里的作品');
      expect(offline.cachedAt, isNotNull);
    });

    test('在线取到详情后断网，详情能回退到缓存', () async {
      await repository.fetchDetail('W-1');

      source.offline = true;
      final offline = await repository.fetchDetail('W-1');

      expect(offline.fromCache, isTrue);
      expect(offline.value.title, '缓存里的作品');
    });
  });

  group('B2 未缓存的内容离线时明确提示，不崩溃', () {
    test('断网时打开没缓存过的详情，抛网络错误而不是空数据', () async {
      source.offline = true;
      await expectLater(
        repository.fetchDetail('W-never-cached'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            ApiErrorCode.network,
          ),
        ),
      );
    });

    test('断网时查没缓存过的列表，同样抛网络错误', () async {
      source.offline = true;
      await expectLater(
        repository.fetchWorks(query: '没搜过的东西'),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('B3 后端不可达时展示缓存并标注「上次同步」', () {
    test('回退结果带 cachedAt，界面据此标注', () async {
      await repository.fetchWorks();
      source.offline = true;

      final offline = await repository.fetchWorks();
      expect(offline.fromCache, isTrue);
      expect(offline.cachedAt, isNotNull);
    });

    test('**404 不回退缓存**——服务端明确答复时不能用缓存顶替', () async {
      await repository.fetchDetail('W-1');
      expect(cache.writeKeys, isNotEmpty);

      // 服务端说「作品不存在」，这是明确答复，不是「拿不到」。
      source.notFound = true;
      await expectLater(
        repository.fetchDetail('W-1'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            ApiErrorCode.workNotFound,
          ),
        ),
      );
    });

    test('列表的 404 同样不回退', () async {
      await repository.fetchWorks();
      source.notFound = true;
      await expectLater(
        repository.fetchWorks(),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            ApiErrorCode.workNotFound,
          ),
        ),
      );
    });
  });

  group('B4 联网恢复后以服务端为准', () {
    test('重新联网后拿到的是服务端数据，且不再是缓存标记', () async {
      await repository.fetchWorks();
      source.offline = true;
      await repository.fetchWorks();

      source.offline = false;
      final recovered = await repository.fetchWorks();

      expect(recovered.fromCache, isFalse);
      expect(recovered.cachedAt, isNull);
    });
  });

  group('缓存键：不同条件不能互相串', () {
    test('排序不同的两页不共用缓存', () async {
      await repository.fetchWorks(sort: WorkSort.id);
      await repository.fetchWorks(sort: WorkSort.rating);

      final idKey = cache.writeKeys.first;
      final ratingKey = cache.writeKeys.last;
      expect(idKey, isNot(ratingKey));
    });

    test('页码不同不共用缓存', () async {
      await repository.fetchWorks(page: 1);
      await repository.fetchWorks(page: 2);
      expect(cache.writeKeys.first, isNot(cache.writeKeys.last));
    });

    test('关键词不同不共用缓存', () async {
      await repository.fetchWorks(query: '甲');
      await repository.fetchWorks(query: '乙');
      expect(cache.writeKeys.first, isNot(cache.writeKeys.last));
    });

    test('离线时按条件精确取回，不会取到别的条件的缓存', () async {
      await repository.fetchWorks(query: '甲');

      source.offline = true;
      // 「乙」没缓存过 → 必须报错，不能拿「甲」的缓存顶上。
      await expectLater(
        repository.fetchWorks(query: '乙'),
        throwsA(isA<ApiException>()),
      );

      // 「甲」有缓存 → 正常回退。
      final hit = await repository.fetchWorks(query: '甲');
      expect(hit.fromCache, isTrue);
    });
  });

  group('B5 全程不引入来源站直连', () {
    test('客户端只通过仓储访问数据，缓存里没有来源站地址', () async {
      await repository.fetchWorks();
      await repository.fetchDetail('W-1');

      // 缓存里存的全是平台返回的结构化数据，不含任何来源站 URL。
      expect(cache.writeKeys, isNotEmpty);
      for (final key in cache.writeKeys) {
        expect(key, isNot(contains('http')));
        expect(key, isNot(contains('154.8')));
      }
    });
  });

  group('界面：离线时必须提示「上次同步」', () {
    testWidgets('列表页在数据来自缓存时显示离线提示', (tester) async {
      // 第一次在线跑一遍，把列表写进缓存。
      await tester.pumpWidget(_app(source, cache, key: const ValueKey('online')));
      await tester.pumpAndSettle();

      // 在线时不应有离线提示。
      expect(find.textContaining('当前离线'), findsNothing);

      // 断网后**重开 App**：换一个 key 让 Riverpod 建新的容器，
      // 等价于进程重启后重新拉数据——这时只能靠缓存。
      source.offline = true;
      await tester.pumpWidget(_app(source, cache, key: const ValueKey('offline')));
      await tester.pumpAndSettle();

      expect(find.textContaining('当前离线'), findsOneWidget);
      // 内容照常展示——离线不是「作品没了」。
      expect(find.text('缓存里的作品'), findsWidgets);
    });

    testWidgets('详情页在数据来自缓存时显示离线提示', (tester) async {
      // 先在线打开一次，让详情进缓存。
      await tester.pumpWidget(_app(source, cache, key: const ValueKey('online')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('缓存里的作品').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('当前离线'), findsNothing);

      // 断网后重新进入详情页（新容器 = 重开 App）。
      source.offline = true;
      await tester.pumpWidget(_app(source, cache, key: const ValueKey('offline')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('缓存里的作品').first);
      await tester.pumpAndSettle();

      expect(find.textContaining('当前离线'), findsOneWidget);
      // 内容照常展示——不能因为离线就把作品藏起来。
      // 「简介」既是小节标题也是正文里的词，用 findsWidgets 即可，
      // 这里要证明的是「详情正文还在」，不是它出现几次。
      expect(find.textContaining('简介'), findsWidgets);
    });
  });
}

/// 造一个 App。
///
/// [key] 用来区分「重开 App」：Riverpod 的 [ProviderScope] 在 widget 类型与
/// key 都不变时会**复用同一个容器**，状态也就留着——那就不是「重开」了。
Widget _app(
  _SwitchableWorkSource source,
  InMemoryWorkCache cache, {
  required Key key,
}) {
  return ProviderScope(
    key: key,
    overrides: [
      appInitialLocationProvider.overrideWithValue(RoutePaths.contents),
      ...authOverrides(),
      // 整个仓储一起覆盖：仓储层的缓存只在非 mock 模式下才挂上，
      // 测试要能自由组合「离线数据源 + 内存缓存」。
      workRepositoryProvider.overrideWithValue(
        WorkRepository(source, cache: cache),
      ),
      collectionRepositoryProvider.overrideWithValue(
        _emptyCollectionRepository(),
      ),
    ],
    child: const OtakuApp(),
  );
}

/// 收藏仓储的替身：离线测试不关心收藏，但列表页会读它。
CollectionRepository _emptyCollectionRepository() {
  return CollectionRepository(_EmptyCollectionDataSource());
}

class _EmptyCollectionDataSource
    implements CollectionDataSource {
  @override
  Future<List<CollectionEntry>> fetchAll({CollectionStatus? status}) async =>
      const [];

  @override
  Future<CollectionState> fetchState(String workId) async =>
      CollectionState(workId: workId, collected: false);

  @override
  Future<CollectionState> add(String workId, {CollectionStatus? status}) async =>
      CollectionState(workId: workId, collected: true, status: status);

  @override
  Future<CollectionState> updateStatus(
    String workId,
    CollectionStatus? status,
  ) async => CollectionState(workId: workId, collected: true, status: status);

  @override
  Future<void> remove(String workId) async {}
}
