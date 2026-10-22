import 'dart:convert';

import 'package:hive_ce_flutter/hive_flutter.dart';

import '../../data/models/collection_entry.dart';
import 'collection_cache.dart';
import 'work_cache.dart' show CachedEntry;

/// 基于 Hive 的收藏缓存。
///
/// 与 `HiveWorkCache` 同一套做法：**存 JSON 字符串而不是对象**，省掉
/// `TypeAdapter` 与 codegen；代价是每次读写多一次编解码，收益是模型加字段时
/// 旧缓存解析失败就当没有缓存，不会把半个字段的旧数据当新数据用。
///
/// **失败即视为无缓存**：读缓存时任何异常都返回 `null`。缓存坏了最多是
/// 「离线时看不到收藏」，不该让 App 起不来。
class HiveCollectionCache implements CollectionCache {
  HiveCollectionCache(this._box);

  final Box<String> _box;

  /// 盒的名字。与作品缓存分开：两者的清理时机不同
  /// （退出登录要清收藏、作品缓存可以留着）。
  static const String boxName = 'otaku_collection_cache';

  static Future<HiveCollectionCache> open() async {
    final box = await Hive.openBox<String>(boxName);
    return HiveCollectionCache(box);
  }

  @override
  Future<CachedEntry<List<CollectionEntry>>?> read(
    CollectionCacheKey key,
  ) async {
    final raw = await _readRaw(key.storageKey);
    if (raw == null) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final payload = decoded['payload'];
      final cachedAt = decoded['cached_at'];
      if (payload is! List || cachedAt is! String) return null;

      final at = DateTime.tryParse(cachedAt);
      if (at == null) return null;

      final items = <CollectionEntry>[];
      for (final item in payload) {
        if (item is! Map) continue;
        try {
          items.add(CollectionEntry.fromJson(Map<String, dynamic>.from(item)));
        } on FormatException {
          // 单条坏数据不该让整份缓存作废：跳过它，剩下的照常显示。
          continue;
        }
      }
      return CachedEntry(value: items, cachedAt: at);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(
    CollectionCacheKey key,
    List<CollectionEntry> entries,
  ) async {
    final envelope = jsonEncode({
      'cached_at': DateTime.now().toUtc().toIso8601String(),
      'payload': [for (final entry in entries) entry.toJson()],
    });
    try {
      await _box.put(key.storageKey, envelope);
    } catch (_) {
      // 写失败（磁盘满）不影响在线浏览，缓存本来就是尽力而为。
    }
  }

  @override
  Future<void> clearUser(String userId) async {
    final prefix = 'collection:$userId\u0000';
    try {
      final keys = _box.keys.where((k) => '$k'.startsWith(prefix)).toList();
      await _box.deleteAll(keys);
    } catch (_) {
      // 清不掉也让它过去：退出登录不能被缓存失败挡住。
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _box.clear();
    } catch (_) {
      // 同上。
    }
  }

  Future<String?> _readRaw(String storageKey) async {
    try {
      return _box.get(storageKey);
    } catch (_) {
      // 读盘失败（文件损坏、权限问题）不该让调用方崩，视为没有缓存。
      return null;
    }
  }
}
