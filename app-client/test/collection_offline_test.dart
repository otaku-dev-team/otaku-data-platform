import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/core/storage/collection_cache.dart';
import 'package:otaku_app/core/storage/collection_cache_provider.dart';
import 'package:otaku_app/core/storage/memory_collection_cache.dart';
import 'package:otaku_app/data/datasources/collection_data_source.dart';
import 'package:otaku_app/data/models/collection_entry.dart';
import 'package:otaku_app/data/models/collection_state.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/data/repositories/collection_repository.dart';
import 'package:otaku_app/features/auth/auth_controller.dart';
import 'package:otaku_app/features/collection/collection_controller.dart';

import 'support/test_overrides.dart';

/// 可在「在线 / 离线」之间切换的收藏数据源。
class _SwitchableCollectionSource implements CollectionDataSource {
  _SwitchableCollectionSource([List<CollectionEntry>? items])
    : _items = items ?? const [];

  List<CollectionEntry> _items;

  /// 非 null 时 `fetchAll` 直接抛它。
  ApiException? failure;

  int fetchAllCalls = 0;
  final List<CollectionStatus?> requestedStatuses = [];

  void goOffline() =>
      failure = const ApiException(
        code: ApiErrorCode.network,
        message: '网络不可达',
      );

  void goOnline() => failure = null;

  @override
  Future<List<CollectionEntry>> fetchAll({CollectionStatus? status}) async {
    fetchAllCalls++;
    requestedStatuses.add(status);
    final error = failure;
    if (error != null) throw error;
    return _items;
  }

  @override
  Future<CollectionState> fetchState(String workId) async =>
      CollectionState(workId: workId, collected: false);

  @override
  Future<CollectionState> add(
    String workId, {
    CollectionStatus? status,
  }) async => CollectionState(workId: workId, collected: true, status: status);

  @override
  Future<CollectionState> updateStatus(
    String workId,
    CollectionStatus? status,
  ) async => CollectionState(workId: workId, collected: true, status: status);

  @override
  Future<void> remove(String workId) async {
    _items = [for (final item in _items) if (item.workId != workId) item];
  }
}

CollectionEntry _entry(String id, {CollectionStatus? status}) => CollectionEntry(
  workId: id,
  workType: WorkType.anime,
  title: '作品 $id',
  status: status,
);

/// 后端不可达时才会走缓存的那种错误。
const ApiException _offline = ApiException(
  code: ApiErrorCode.network,
  message: '网络不可达',
);

/// 服务端的明确答复，不可以用缓存顶替。
const ApiException _unauthorized = ApiException(
  code: ApiErrorCode.unauthorized,
  message: '登录已过期',
  statusCode: 401,
);

void main() {
  group('收藏缓存键', () {
    test('账号不同就是不同的键', () {
      final alice = CollectionCacheKey(userId: 'alice', status: null);
      final bob = CollectionCacheKey(userId: 'bob', status: null);
      expect(alice, isNot(bob));
      expect(alice.storageKey, isNot(bob.storageKey));
    });

    test('同一账号的不同筛选也是不同的键', () {
      final all = CollectionCacheKey(userId: 'alice', status: null);
      final want = CollectionCacheKey(
        userId: 'alice',
        status: CollectionStatus.want,
      );
      expect(all, isNot(want));
    });

    test('clearUser 的前缀不会误伤 id 是它前缀的另一个账号', () async {
      final cache = InMemoryCollectionCache();
      await cache.write(
        const CollectionCacheKey(userId: 'alice'),
        [_entry('A-1')],
      );
      await cache.write(
        const CollectionCacheKey(userId: 'alice2'),
        [_entry('B-1')],
      );

      await cache.clearUser('alice');

      expect(
        await cache.read(const CollectionCacheKey(userId: 'alice')),
        isNull,
      );
      // alice2 必须还在：前缀匹配带了分隔符，`alice` 不会吃掉 `alice2`。
      expect(
        await cache.read(const CollectionCacheKey(userId: 'alice2')),
        isNotNull,
      );
    });
  });

  group('收藏仓储的离线回退', () {
    test('在线成功时写缓存，返回的是实时数据', () async {
      final source = _SwitchableCollectionSource([_entry('W-1')]);
      final cache = InMemoryCollectionCache();
      final repo = CollectionRepository(source, cache: cache);

      final result = await repo.fetchAll(userId: 'alice');

      expect(result.fromCache, isFalse);
      expect(result.value.single.workId, 'W-1');
      expect(cache.writeKeys, isNotEmpty);
    });

    test('后端不可达时回退缓存，并标注来自缓存', () async {
      final source = _SwitchableCollectionSource([_entry('W-1')]);
      final cache = InMemoryCollectionCache();
      final repo = CollectionRepository(source, cache: cache);

      await repo.fetchAll(userId: 'alice');
      source.goOffline();

      final result = await repo.fetchAll(userId: 'alice');

      expect(result.fromCache, isTrue);
      expect(result.cachedAt, isNotNull);
      expect(result.value.single.workId, 'W-1');
    });

    test('没有缓存又离线：照原样抛错，不伪造空列表', () async {
      final source = _SwitchableCollectionSource()..goOffline();
      final repo = CollectionRepository(source, cache: InMemoryCollectionCache());

      await expectLater(
        repo.fetchAll(userId: 'alice'),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', ApiErrorCode.network),
        ),
      );
    });

    test('401 这类明确答复不回退缓存', () async {
      final source = _SwitchableCollectionSource([_entry('W-1')]);
      final cache = InMemoryCollectionCache();
      final repo = CollectionRepository(source, cache: cache);

      await repo.fetchAll(userId: 'alice');
      source.failure = _unauthorized;

      // 缓存里明明有数据，但服务端在说「你没资格看」，拿缓存顶上等于替它编结论。
      await expectLater(repo.fetchAll(userId: 'alice'), throwsA(isA<ApiException>()));
    });

    test('状态筛选进缓存键：「全部」与「想看」各存一份', () async {
      final source = _SwitchableCollectionSource([_entry('W-1')]);
      final cache = InMemoryCollectionCache();
      final repo = CollectionRepository(source, cache: cache);

      await repo.fetchAll(userId: 'alice');
      await repo.fetchAll(userId: 'alice', status: CollectionStatus.want);

      expect(cache.writeKeys.toSet().length, 2);
    });

    test('remember 把服务端确认过的列表写回缓存', () async {
      final source = _SwitchableCollectionSource([_entry('W-1')]);
      final cache = InMemoryCollectionCache();
      final repo = CollectionRepository(source, cache: cache);

      await repo.remember('alice', [_entry('W-1', status: CollectionStatus.watched)]);
      source.goOffline();

      final result = await repo.fetchAll(userId: 'alice');

      expect(result.fromCache, isTrue);
      expect(result.value.single.status, CollectionStatus.watched);
    });
  });

  group('按账号隔离', () {
    test('A 的缓存不会被 B 读到', () async {
      final source = _SwitchableCollectionSource([_entry('ALICE-1')]);
      final cache = InMemoryCollectionCache();
      final repo = CollectionRepository(source, cache: cache);

      await repo.fetchAll(userId: 'alice');
      source.goOffline();

      // bob 从未成功拉过，离线时不能拿到 alice 的列表。
      await expectLater(
        repo.fetchAll(userId: 'bob'),
        throwsA(isA<ApiException>()),
      );
    });

    test('换账号后两个人的列表各自独立', () async {
      final source = _SwitchableCollectionSource([_entry('ALICE-1')]);
      final cache = InMemoryCollectionCache();
      final repo = CollectionRepository(source, cache: cache);

      await repo.fetchAll(userId: 'alice');
      source._items = [_entry('BOB-1')];
      await repo.fetchAll(userId: 'bob');
      source.goOffline();

      expect(
        (await repo.fetchAll(userId: 'alice')).value.single.workId,
        'ALICE-1',
      );
      expect((await repo.fetchAll(userId: 'bob')).value.single.workId, 'BOB-1');
    });

    test('退出登录清掉这个人的缓存', () async {
      final source = _SwitchableCollectionSource([_entry('W-1')]);
      final cache = InMemoryCollectionCache();
      final repo = CollectionRepository(source, cache: cache);

      await repo.fetchAll(userId: 'alice');
      await cache.clearUser('alice');
      source.goOffline();

      await expectLater(repo.fetchAll(userId: 'alice'), throwsA(isA<ApiException>()));
    });
  });

  group('收藏控制器：离线只读', () {
    ProviderContainer container(
      _SwitchableCollectionSource source,
      CollectionCache cache, {
      String? token,
    }) {
      final c = ProviderContainer(
        overrides: [
          ...authOverrides(token: token),
          collectionDataSourceProvider.overrideWithValue(source),
          collectionCacheProvider.overrideWithValue(cache),
          collectionRepositoryProvider.overrideWithValue(
            CollectionRepository(source, cache: cache),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    Future<void> settleAuth(ProviderContainer c) async {
      c.read(authControllerProvider);
      for (var i = 0; i < 50; i++) {
        if (c.read(authControllerProvider).status != AuthStatus.checking) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }

    test('离线时改状态被拒，且说明只能查看', () async {
      final source = _SwitchableCollectionSource([
        _entry('W-1', status: CollectionStatus.want),
      ]);
      final cache = InMemoryCollectionCache();
      final c = container(source, cache, token: signedInToken);
      await settleAuth(c);

      await c.read(collectionControllerProvider.future);
      source.goOffline();
      await c.read(collectionControllerProvider.notifier).refresh();

      final state = c.read(collectionControllerProvider).value!;
      expect(state.fromCache, isTrue);

      final error = await c
          .read(collectionControllerProvider.notifier)
          .changeStatus('W-1', CollectionStatus.watching);

      expect(error, isNotNull);
      expect(error!.message, contains('只能查看'));
    });

    test('离线时删除被拒', () async {
      final source = _SwitchableCollectionSource([_entry('W-1')]);
      final cache = InMemoryCollectionCache();
      final c = container(source, cache, token: signedInToken);
      await settleAuth(c);

      await c.read(collectionControllerProvider.future);
      source.goOffline();
      await c.read(collectionControllerProvider.notifier).refresh();

      final error = await c
          .read(collectionControllerProvider.notifier)
          .remove('W-1');

      expect(error, isNotNull);
      // 拒掉的同时不能把界面改成「删掉了」——那份数据还在服务端。
      expect(
        c.read(collectionControllerProvider).value!.value,
        hasLength(1),
      );
    });

    test('在线改状态成功后，缓存跟着更新', () async {
      final source = _SwitchableCollectionSource([
        _entry('W-1', status: CollectionStatus.want),
      ]);
      final cache = InMemoryCollectionCache();
      final c = container(source, cache, token: signedInToken);
      await settleAuth(c);

      await c.read(collectionControllerProvider.future);
      final error = await c
          .read(collectionControllerProvider.notifier)
          .changeStatus('W-1', CollectionStatus.watching);
      expect(error, isNull);

      source.goOffline();
      await c.read(collectionControllerProvider.notifier).refresh();
      final cached = c.read(collectionControllerProvider).value!;
      expect(cached.fromCache, isTrue);
      expect(cached.value.single.status, CollectionStatus.watching);
    });

    test('切到另一个账号：离线时不显示上一个人的收藏', () async {
      // 同一个缓存实例模拟「同一台设备」。
      final cache = InMemoryCollectionCache();

      final aliceSource = _SwitchableCollectionSource([_entry('ALICE-1')]);
      final alice = container(aliceSource, cache, token: signedInToken);
      await settleAuth(alice);
      await alice.read(collectionControllerProvider.future);
      expect(
        alice.read(collectionControllerProvider).value!.value.single.workId,
        'ALICE-1',
      );

      // bob 在同一台设备上登录，且此时处于离线。
      final bobSource = _SwitchableCollectionSource([_entry('BOB-1')])
        ..goOffline();
      final bob = container(bobSource, cache, token: 'mock-token-bob');
      await settleAuth(bob);

      // bob 没有自己的缓存，不能拿 alice 的收藏顶上——等它这次取数走完。
      await expectLater(
        bob.read(collectionControllerProvider.future),
        throwsA(isA<ApiException>()),
        reason: 'bob 没有自己的缓存，不能拿 alice 的收藏顶上',
      );
    });
  });

  group('收藏条目的序列化', () {
    test('toJson / fromJson 往返一致', () {
      final entry = CollectionEntry(
        workId: 'W-1',
        workType: WorkType.comic,
        title: '往返作品',
        coverUrl: 'https://example.com/c.png',
        status: CollectionStatus.watching,
        updatedAt: DateTime.utc(2026, 10, 22),
      );

      final restored = CollectionEntry.fromJson(entry.toJson());

      expect(restored.workId, entry.workId);
      expect(restored.workType, entry.workType);
      expect(restored.title, entry.title);
      expect(restored.coverUrl, entry.coverUrl);
      expect(restored.status, entry.status);
      expect(restored.updatedAt, entry.updatedAt);
    });

    test('没状态、没封面的条目也能往返', () {
      const entry = CollectionEntry(
        workId: 'W-2',
        workType: WorkType.anime,
        title: '裸条目',
      );

      final restored = CollectionEntry.fromJson(entry.toJson());

      expect(restored.status, isNull);
      expect(restored.coverUrl, isNull);
      expect(restored.updatedAt, isNull);
    });
  });

  group('离线错误只在不可达时出现', () {
    test('timeout 也算不可达，可以回退', () async {
      final source = _SwitchableCollectionSource([_entry('W-1')]);
      final cache = InMemoryCollectionCache();
      final repo = CollectionRepository(source, cache: cache);

      await repo.fetchAll(userId: 'alice');
      source.failure = const ApiException(
        code: ApiErrorCode.timeout,
        message: '超时',
      );

      final result = await repo.fetchAll(userId: 'alice');
      expect(result.fromCache, isTrue);
    });

    test('_offline 常量确实是不可达的（守卫用）', () {
      expect(_offline.isUnreachable, isTrue);
      expect(_unauthorized.isUnreachable, isFalse);
    });
  });
}
