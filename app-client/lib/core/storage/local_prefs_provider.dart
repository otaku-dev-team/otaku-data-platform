import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'hive_local_prefs.dart';
import 'local_prefs.dart';
import 'memory_local_prefs.dart';

/// 本机偏好的持有者。
///
/// 与 `WorkCacheHolder` / `RecentViewsHolder` 同一个理由：provider 的 build
/// 不能是异步的，而 `Hive.openBox` 是异步的，所以在 `main()` 里预先打开，
/// provider 同步拿到实例。
///
/// **这里比别处更依赖「同步」**：`MaterialApp` 的 `themeMode` 在第一帧就要定，
/// 异步读会让应用先按系统主题画一帧，再跳成用户选的那套。
///
/// **打开失败降级为内存实现**：偏好不是 App 启动的前提。
class LocalPrefsHolder {
  LocalPrefsHolder._();

  static final LocalPrefsHolder instance = LocalPrefsHolder._();

  LocalPrefs? _prefs;

  /// 打开真正的 Hive 存储。`main()` 里在 `runApp` 之前调用。
  ///
  /// 返回 false 表示已降级为内存实现。
  Future<bool> initialize() async {
    if (_prefs != null) return true;
    try {
      _prefs = await HiveLocalPrefs.open();
      return true;
    } catch (_) {
      _prefs = InMemoryLocalPrefs();
      return false;
    }
  }

  /// 给 provider 用的实例。未初始化时是内存实现。
  LocalPrefs get prefs => _prefs ??= InMemoryLocalPrefs();
}

/// 本机偏好。
///
/// 测试里换成干净的内存实现：
/// `localPrefsProvider.overrideWithValue(InMemoryLocalPrefs())`。
/// **必须换**——默认指向单例，同一个测试文件里的用例会互相看到对方写的值。
final localPrefsProvider = Provider<LocalPrefs>((ref) {
  return LocalPrefsHolder.instance.prefs;
});
