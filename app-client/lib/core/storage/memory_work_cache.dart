import '../../data/models/related_works.dart';
import '../../data/models/work.dart';
import 'work_cache.dart';

/// 内存缓存。单测与 widget 测试用。
///
/// 真实实现（Hive）要平台通道，测试环境里调不了；
/// 这个实现还让「什么时候写缓存、什么时候读缓存」在测试里可断言——
/// 它记下每次访问，测试能验证「写过一次之后才有缓存可读」。
class InMemoryWorkCache implements WorkCache {
  final Map<String, CachedListPage> _lists = {};
  final Map<String, Work> _details = {};
  final Map<String, RelatedWorks> _related = {};

  final Map<String, DateTime> _cachedAt = {};

  /// 记录每次读操作，测试用来断言「确实没读缓存」这类行为。
  final List<String> readKeys = [];

  /// 记录每次写操作的键。
  final List<String> writeKeys = [];

  @override
  Future<CachedEntry<CachedListPage>?> readList(ListCacheKey key) async {
    readKeys.add(key.storageKey);
    final page = _lists[key.storageKey];
    if (page == null) return null;
    final at = _cachedAt[key.storageKey];
    if (at == null) return null;
    return CachedEntry(value: page, cachedAt: at);
  }

  @override
  Future<void> writeList(ListCacheKey key, CachedListPage page) async {
    writeKeys.add(key.storageKey);
    _lists[key.storageKey] = page;
    _cachedAt[key.storageKey] = DateTime.now();
  }

  @override
  Future<CachedEntry<Work>?> readDetail(DetailCacheKey key) async {
    readKeys.add(key.storageKey);
    final work = _details[key.storageKey];
    if (work == null) return null;
    final at = _cachedAt[key.storageKey];
    if (at == null) return null;
    return CachedEntry(value: work, cachedAt: at);
  }

  @override
  Future<void> writeDetail(DetailCacheKey key, Work work) async {
    writeKeys.add(key.storageKey);
    _details[key.storageKey] = work;
    _cachedAt[key.storageKey] = DateTime.now();
  }

  @override
  Future<CachedEntry<RelatedWorks>?> readRelated(RelatedCacheKey key) async {
    readKeys.add(key.storageKey);
    final value = _related[key.storageKey];
    if (value == null) return null;
    final at = _cachedAt[key.storageKey];
    if (at == null) return null;
    return CachedEntry(value: value, cachedAt: at);
  }

  @override
  Future<void> writeRelated(RelatedCacheKey key, RelatedWorks related) async {
    writeKeys.add(key.storageKey);
    _related[key.storageKey] = related;
    _cachedAt[key.storageKey] = DateTime.now();
  }

  @override
  Future<void> clear() async {
    _lists.clear();
    _details.clear();
    _related.clear();
    _cachedAt.clear();
  }
}
