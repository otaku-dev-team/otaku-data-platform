import '../../data/models/collection_entry.dart';
import 'collection_cache.dart';
import 'work_cache.dart' show CachedEntry;

/// 内存收藏缓存。单测与 widget 测试用。
///
/// 真实实现（Hive）要平台通道，测试环境调不了；同时它把「读过哪些键、写过哪些键」
/// 暴露出来，测试能直接断言「A 的缓存没被 B 读到」这类隔离行为。
class InMemoryCollectionCache implements CollectionCache {
  final Map<String, List<CollectionEntry>> _entries = {};
  final Map<String, DateTime> _cachedAt = {};

  /// 每次读操作的键，测试用来断言「确实没读缓存」。
  final List<String> readKeys = [];

  /// 每次写操作的键。
  final List<String> writeKeys = [];

  @override
  Future<CachedEntry<List<CollectionEntry>>?> read(
    CollectionCacheKey key,
  ) async {
    readKeys.add(key.storageKey);
    final value = _entries[key.storageKey];
    final at = _cachedAt[key.storageKey];
    if (value == null || at == null) return null;
    return CachedEntry(value: value, cachedAt: at);
  }

  @override
  Future<void> write(
    CollectionCacheKey key,
    List<CollectionEntry> entries,
  ) async {
    writeKeys.add(key.storageKey);
    _entries[key.storageKey] = entries;
    _cachedAt[key.storageKey] = DateTime.now();
  }

  @override
  Future<void> clearUser(String userId) async {
    // 带分隔符的前缀：只匹配这个账号，不会误伤「id 是它前缀」的另一个账号
    // （`alice` 与 `alice2` 靠 `\u0000` 区分开）。
    _entries.removeWhere((k, _) => k.startsWith(_prefix(userId)));
    _cachedAt.removeWhere((k, _) => k.startsWith(_prefix(userId)));
  }

  @override
  Future<void> clear() async {
    _entries.clear();
    _cachedAt.clear();
  }

  static String _prefix(String userId) => 'collection:$userId\u0000';
}
