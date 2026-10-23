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
  HiveWorkCache(this._box);

  /// 打开的 Hive 盒。
  final Box<String> _box;

  /// 盒的名字。改名字等于换一份空缓存（老盒子留在磁盘上）。
  static const String boxName = 'otaku_work_cache';

  /// 打开缓存盒。调用方负责在 `main()` 里 `Hive.initFlutter()` 之后调用。
  static Future<HiveWorkCache> open() async {
    final box = await Hive.openBox<String>(boxName);
    return HiveWorkCache(box);
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
    }
  }
}
