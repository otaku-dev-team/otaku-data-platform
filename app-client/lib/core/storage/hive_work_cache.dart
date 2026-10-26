import 'dart:convert';

import 'package:hive_ce_flutter/hive_flutter.dart';

import '../../data/models/related_works.dart';
import '../../data/models/work.dart';
import '../../data/models/work_summary.dart';
import 'work_cache.dart';

/// 基于 Hive 的作品缓存。
///
/// **存 JSON 字符串而不是对象**：Hive 原生支持 Map/List，
/// 但把模型直接存进去需要给每个模型写 `TypeAdapter`（还得配 codegen）。
/// 存 JSON 字符串的代价是每次读写多一次编解码，收益是：
/// - 不引 codegen，CI 与本地都不用多跑 `build_runner`；
/// - 缓存格式与模型解耦——模型加字段时，旧缓存解析失败就当没有缓存，
///   不会把半个字段的旧数据当成新数据用。
///
/// **失败即视为无缓存**：读缓存时任何异常都返回 `null`。
/// 缓存坏了最多是「离线时看不到内容」，不该让整个 App 起不来。
class HiveWorkCache implements WorkCache {
  HiveWorkCache(
    this._box, {
    this.maxEntries = defaultMaxEntries,
    this.maxBytes = defaultMaxBytes,
  });

  /// 打开的 Hive 盒。
  final Box<String> _box;

  /// 条目上限与字节上限。
  ///
  /// **为什么必须有上限**：列表键里带 `type / query / tag / sort / page / pageSize`，
  /// 用户每搜一个词、每翻一页、每换一次筛选就是一条新缓存。此前只有设置页的
  /// 手动「清除」——用户不点，它就无限长。离线缓存是「尽力而为」，
  /// 不该成为磁盘占用不可控的东西。
  static const int defaultMaxEntries = 400;
  static const int defaultMaxBytes = 8 * 1024 * 1024;

  final int maxEntries;
  final int maxBytes;

  /// 淘汰到上限的这个比例就停手：留出余量，避免「刚清完又立刻超限」反复扫描。
  static const double _lowWater = 0.8;

  /// 盒的名字。改名字等于换一份空缓存（老盒子留在磁盘上）。
  static const String boxName = 'otaku_work_cache';

  /// 打开缓存盒。调用方负责在 `main()` 里 `Hive.initFlutter()` 之后调用。
  static Future<HiveWorkCache> open() async {
    final box = await Hive.openBox<String>(boxName);
    final cache = HiveWorkCache(box);
    // 老版本没有上限：升级后第一次启动可能面对一个膨胀的盒子。
    // 在这里收一次，别拖到第一次写入时才淘汰——那一次会落在用户的浏览路径上。
    await cache.enforceLimits();
    return cache;
  }

  @override
  Future<CachedEntry<CachedListPage>?> readList(ListCacheKey key) async {
    final raw = await _read(key.storageKey);
    if (raw == null) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final payload = decoded['payload'];
      final cachedAt = decoded['cached_at'];
      if (payload is! Map || cachedAt is! String) return null;

      final at = DateTime.tryParse(cachedAt);
      if (at == null) return null;

      final items = <WorkSummary>[];
      final rawItems = payload['items'];
      if (rawItems is List) {
        for (final item in rawItems) {
          if (item is! Map) continue;
          try {
            items.add(WorkSummary.fromJson(Map<String, dynamic>.from(item)));
          } on FormatException {
            // 单条坏数据不该让整页缓存作废：跳过它，剩下的照常显示。
            continue;
          }
        }
      }

      return CachedEntry(
        value: CachedListPage(
          items: items,
          total: _asInt(payload['total'], items.length),
          page: _asInt(payload['page'], key.page),
          pageSize: _asInt(payload['page_size'], key.pageSize),
          totalPages: _asInt(payload['total_pages'], 1),
        ),
        cachedAt: at,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> writeList(ListCacheKey key, CachedListPage page) async {
    await _write(key.storageKey, {
      'payload': {
        'items': [for (final item in page.items) item.toJson()],
        'total': page.total,
        'page': page.page,
        'page_size': page.pageSize,
        'total_pages': page.totalPages,
      },
    });
  }

  static int _asInt(Object? raw, int fallback) => switch (raw) {
    final num n => n.toInt(),
    final String s => int.tryParse(s) ?? fallback,
    _ => fallback,
  };

  @override
  Future<CachedEntry<Work>?> readDetail(DetailCacheKey key) async {
    final raw = await _read(key.storageKey);
    if (raw == null) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final payload = decoded['payload'];
      final cachedAt = decoded['cached_at'];
      if (payload is! Map || cachedAt is! String) return null;

      final at = DateTime.tryParse(cachedAt);
      if (at == null) return null;
      return CachedEntry(
        value: Work.fromJson(Map<String, dynamic>.from(payload)),
        cachedAt: at,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> writeDetail(DetailCacheKey key, Work work) async {
    await _write(key.storageKey, {'payload': work.toJson()});
  }

  @override
  Future<CachedEntry<RelatedWorks>?> readRelated(RelatedCacheKey key) async {
    final raw = await _read(key.storageKey);
    if (raw == null) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final payload = decoded['payload'];
      final cachedAt = decoded['cached_at'];
      if (payload is! Map || cachedAt is! String) return null;

      final at = DateTime.tryParse(cachedAt);
      if (at == null) return null;
      return CachedEntry(
        value: RelatedWorks.fromJson(Map<String, dynamic>.from(payload)),
        cachedAt: at,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> writeRelated(RelatedCacheKey key, RelatedWorks related) async {
    await _write(key.storageKey, {'payload': related.toJson()});
  }

  @override
  Future<void> clear() async {
    await _box.clear();
  }

  @override
  Future<CacheUsage> usage() async {
    try {
      var entries = 0;
      var bytes = 0;
      // 逐个读值而不是读 `box.length`：要的是字节数，而 `length` 只给条数。
      // 缓存盒子不设 TTL、条目也只有几百到几千，遍历一次的代价可以接受，
      // 设置页本来就不是高频页面。
      for (final key in _box.keys) {
        final value = _box.get(key);
        if (value is! String) continue;
        entries++;
        bytes += utf8.encode('$key').length + utf8.encode(value).length;
      }
      return CacheUsage(entries: entries, bytes: bytes);
    } catch (_) {
      return CacheUsage.empty;
    }
  }

  Future<String?> _read(String storageKey) async {
    try {
      return _box.get(storageKey);
    } catch (_) {
      // 读盘失败（文件损坏、权限问题）不该让调用方崩，视为没有缓存。
      return null;
    }
  }

  Future<void> _write(String storageKey, Map<String, dynamic> payload) async {
    final envelope = jsonEncode({
      'cached_at': DateTime.now().toUtc().toIso8601String(),
      'payload': payload['payload'],
    });
    try {
      await _box.put(storageKey, envelope);
    } catch (_) {
      // 写失败（磁盘满）不影响在线浏览，缓存本来就是尽力而为。
      return;
    }
    await enforceLimits(keep: storageKey);
  }

  /// 把缓存收敛到上限以内：按**写入时间**淘汰最旧的，直到回落到低水位。
  ///
  /// 注意这不是 LRU：`cached_at` 是**数据新鲜度**的语义（离线时要显示「上次同步」），
  /// 读一次就改它会把那个语义弄坏。真做 LRU 得再加一个 `last_access` 字段，
  /// 收益不值——缓存本来就是「浏览过的页面」，写入顺序与访问顺序高度重合。
  ///
  /// [keep] 是刚写入的键，无论如何不淘汰它（否则一次大响应可能把自己挤掉，
  /// 表现为「刚看完的详情页离线打不开」）。
  Future<void> enforceLimits({String? keep}) async {
    try {
      final entries = <_CacheEntryInfo>[];
      final broken = <String>[];

      for (final rawKey in _box.keys) {
        final key = '$rawKey';
        final value = _box.get(rawKey);
        if (value is! String) {
          broken.add(key);
          continue;
        }
        final cachedAt = _readCachedAt(value);
        if (cachedAt == null) {
          // 解不开的记录读的时候也是 null，留着只占地方。
          broken.add(key);
          continue;
        }
        entries.add(
          _CacheEntryInfo(
            key,
            cachedAt,
            utf8.encode(key).length + utf8.encode(value).length,
          ),
        );
      }
      if (broken.isNotEmpty) await _box.deleteAll(broken);

      var count = entries.length;
      var bytes = entries.fold<int>(0, (sum, entry) => sum + entry.bytes);
      if (count <= maxEntries && bytes <= maxBytes) return;

      entries.sort((a, b) => a.cachedAt.compareTo(b.cachedAt));
      final targetCount = (maxEntries * _lowWater).floor();
      final targetBytes = (maxBytes * _lowWater).floor();

      final doomed = <String>[];
      for (final entry in entries) {
        if (count <= targetCount && bytes <= targetBytes) break;
        if (entry.key == keep) continue;
        doomed.add(entry.key);
        count--;
        bytes -= entry.bytes;
      }
      if (doomed.isNotEmpty) await _box.deleteAll(doomed);
    } catch (_) {
      // 清理失败最多是占点磁盘；缓存不能因为它把浏览路径搞崩。
    }
  }

  /// 从信封里取写入时刻。解不开就返回 null（视为坏记录）。
  static DateTime? _readCachedAt(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final cachedAt = decoded['cached_at'];
      if (cachedAt is! String) return null;
      return DateTime.tryParse(cachedAt);
    } catch (_) {
      return null;
    }
  }
}

/// 淘汰时用的一条记录：键、写入时刻、占用字节。
class _CacheEntryInfo {
  const _CacheEntryInfo(this.key, this.cachedAt, this.bytes);

  final String key;
  final DateTime cachedAt;
  final int bytes;
}
