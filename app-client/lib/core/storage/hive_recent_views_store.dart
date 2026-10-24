import 'package:hive_ce_flutter/hive_flutter.dart';

import '../../data/models/recent_view.dart';
import 'recent_views_store.dart';

/// 基于 Hive 的浏览历史。
///
/// 与 `HiveWorkCache` 同一套做法：**存 JSON 字符串而不是对象**，省掉
/// `TypeAdapter` 与 codegen；一条账号的历史整体存成一份，读写各一次编解码。
///
/// 一个盒子装所有账号，键是 `recent:<账号>`；不同账号互不可见，
/// 换账号也不需要重新打开盒子。
class HiveRecentViewsStore implements RecentViewsStore {
  HiveRecentViewsStore(this._box);

  final Box<String> _box;

  /// 盒的名字。与作品缓存、收藏缓存都分开：三者的清理时机不同。
  static const String boxName = 'otaku_recent_views';

  /// 打开盒子。调用方负责在 `main()` 里 `Hive.initFlutter()` 之后调用。
  static Future<HiveRecentViewsStore> open() async {
    return HiveRecentViewsStore(await Hive.openBox<String>(boxName));
  }

  static String _keyOf(String ownerKey) => 'recent:$ownerKey';

  @override
  List<RecentView> read(String ownerKey) {
    try {
      final raw = _box.get(_keyOf(ownerKey));
      return raw == null ? const <RecentView>[] : RecentViewsCodec.decode(raw);
    } catch (_) {
      // 读盘失败（文件损坏、权限问题）视为没有历史，而不是让首页崩掉。
      return const <RecentView>[];
    }
  }

  @override
  Future<void> write(String ownerKey, List<RecentView> items) async {
    try {
      await _box.put(_keyOf(ownerKey), RecentViewsCodec.encode(items));
    } catch (_) {
      // 写失败（磁盘满）只影响下次启动，本次会话内存里那份仍然有效。
    }
  }

  @override
  Future<void> clear(String ownerKey) async {
    try {
      await _box.delete(_keyOf(ownerKey));
    } catch (_) {
      // 删不掉最坏是「点了清空、重启后又回来」；不该因此让界面报错。
    }
  }
}
