import 'package:hive_ce_flutter/hive_flutter.dart';

import 'local_prefs.dart';

/// 基于 Hive 的本机偏好。
///
/// 与其余几个盒子同一套做法：**存字符串**，不引 `TypeAdapter`。
/// 一个盒子装所有偏好键——这类数据只有几个短值，为「主题」单独开一个盒
/// 只会让 `main()` 里堆一串 `openBox`。
class HiveLocalPrefs implements LocalPrefs {
  HiveLocalPrefs(this._box);

  final Box<String> _box;

  /// 盒的名字。与作品缓存、收藏缓存、浏览历史都分开：
  /// 那三个是按账号/内容清理的，这个不该被「清除缓存」误伤。
  static const String boxName = 'otaku_prefs';

  static Future<HiveLocalPrefs> open() async {
    return HiveLocalPrefs(await Hive.openBox<String>(boxName));
  }

  @override
  String? read(String key) {
    try {
      return _box.get(key);
    } catch (_) {
      // 读盘失败（文件损坏、权限问题）视为没设过，用默认值。
      // 偏好读不出来最多是主题回到跟随系统，不该让 App 起不来。
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _box.put(key, value);
    } catch (_) {
      // 写失败只影响下次启动：本次会话内存里那份状态仍然有效。
    }
  }

  @override
  Future<void> remove(String key) async {
    try {
      await _box.delete(key);
    } catch (_) {
      // 删不掉最坏是「重启后又回来」，不值得让界面报错。
    }
  }
}
