import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/dio_client.dart';
import '../../core/storage/collection_cache.dart';
import '../../core/storage/collection_cache_provider.dart';
import '../datasources/collection_data_source.dart';
import '../datasources/collection_mock_data_source.dart';
import '../datasources/collection_remote_data_source.dart';
import '../models/collection_entry.dart';
import '../models/collection_state.dart';
import 'work_repository.dart' show Fetched;

/// 收藏的门面。控制器只认这一层，Mock 与真实实现互换不影响界面。
class CollectionRepository {
  CollectionRepository(this._dataSource, {this._cache});

  final CollectionDataSource _dataSource;

  /// 离线缓存。为 `null` 时不做缓存（Mock 模式就是这种情况）。
  final CollectionCache? _cache;

  /// 本人收藏列表。
  ///
  /// [userId] 是**必填**而不是可选：它进缓存键，漏掉就等于把一个人的收藏
  /// 缓存到另一个人能读到的地方。宁可让调用方显式传，也不给默认值。
  ///
  /// **在线优先，失败才回退缓存**，规则与作品列表一致：只有后端不可达才用
  /// 缓存兜底，401 / 404 这些明确答复照原样往上抛——拿缓存顶上等于把
  /// 「没有这份数据」说成「有」，与铁律 3 是同一类错误。
  Future<Fetched<List<CollectionEntry>>> fetchAll({
    required String userId,
    CollectionStatus? status,
  }) async {
    final key = CollectionCacheKey(userId: userId, status: status);

    try {
      final items = await _dataSource.fetchAll(status: status);
      await _cache?.write(key, items);
      return Fetched.live(items);
    } on ApiException catch (error) {
      if (!error.isUnreachable) rethrow;
      return _fallback(key, error);
    } on DioException catch (error) {
      final converted = ApiException.fromDio(error);
      if (!converted.isUnreachable) throw converted;
      return _fallback(key, converted);
    } on FormatException catch (error) {
      throw ApiException(
        code: ApiErrorCode.unknown,
        message: '数据格式异常：${error.message}',
      );
    }
  }

  /// 不可达时才走的回退。没有缓存就照原样抛，不伪造空列表——
  /// 「没收藏」和「拿不到」是两件事。
  Future<Fetched<List<CollectionEntry>>> _fallback(
    CollectionCacheKey key,
    ApiException error,
  ) async {
    final cached = await _cache?.read(key);
    if (cached == null) throw error;
    return Fetched.cached(cached.value, cached.cachedAt);
  }

  /// 把一份「服务端确认过」的列表写进缓存。
  ///
  /// 改状态、删除成功后调用：那之后这份列表才是最新真相。不写回去的话，
  /// 用户下次离线打开收藏页会看到改动前的旧列表——离线只读场景下
  /// 这是唯一会被看到的版本，错了没有第二次纠正的机会。
  Future<void> remember(
    String userId,
    List<CollectionEntry> entries, {
    CollectionStatus? status,
  }) async {
    await _cache?.write(
      CollectionCacheKey(userId: userId, status: status),
      entries,
    );
  }

  Future<CollectionState> fetchState(String workId) =>
      _dataSource.fetchState(workId);

  Future<CollectionState> add(String workId, {CollectionStatus? status}) =>
      _dataSource.add(workId, status: status);

  /// 只改状态、不创建。记录不存在会抛 `COLLECTION_REQUIRED`。
  Future<CollectionState> updateStatus(
    String workId,
    CollectionStatus? status,
  ) => _dataSource.updateStatus(workId, status);

  Future<void> remove(String workId) => _dataSource.remove(workId);
}

/// 默认走 Mock；联调时加 `--dart-define=USE_MOCK=false` 切真实接口。
///
/// 与作品列表用同一个开关是有意的：只切一半会出现「作品来自真接口、收藏写着假数据」
/// 的混合状态，那种环境下的 bug 最难判断归属。
final collectionDataSourceProvider = Provider<CollectionDataSource>((ref) {
  if (AppConfig.useMock) return CollectionMockDataSource();
  return RemoteCollectionDataSource(ref.watch(dioProvider));
});

final collectionRepositoryProvider = Provider<CollectionRepository>((ref) {
  return CollectionRepository(
    ref.watch(collectionDataSourceProvider),
    // Mock 模式不接缓存，理由同作品仓储：Mock 数据本来就在本地，
    // 再存一份没有意义，还会让测试出现意外的「缓存命中」。
    cache: AppConfig.useMock ? null : ref.watch(collectionCacheProvider),
  );
});
