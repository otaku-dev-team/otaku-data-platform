import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'collection_cache.dart';
import 'hive_collection_cache.dart';
import 'memory_collection_cache.dart';

/// 收藏缓存的持有者。与 `WorkCacheHolder` 同一个理由：
/// provider 的 build 不能是异步的，而 `Hive.openBox` 是异步的，
/// 所以用一个在 `main()` 里预先打开好的单例，provider 就能同步拿到实例。
///
/// **打开失败时降级为内存缓存**：缓存不是 App 启动的前提。
class CollectionCacheHolder {
  CollectionCacheHolder._();

  static final CollectionCacheHolder instance = CollectionCacheHolder._();

  CollectionCache? _cache;

  Future<bool> initialize() async {
    if (_cache != null) return true;
    try {
      _cache = await HiveCollectionCache.open();
      return true;
    } catch (_) {
      _cache = InMemoryCollectionCache();
      return false;
    }
  }

  CollectionCache get cache => _cache ??= InMemoryCollectionCache();
}

/// 收藏缓存。
///
/// 测试里换实现：`collectionCacheProvider.overrideWithValue(InMemoryCollectionCache())`。
final collectionCacheProvider = Provider<CollectionCache>((ref) {
  return CollectionCacheHolder.instance.cache;
});
