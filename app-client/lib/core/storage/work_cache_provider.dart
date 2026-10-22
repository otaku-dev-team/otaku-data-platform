import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'hive_work_cache.dart';
import 'memory_work_cache.dart';
import 'work_cache.dart';

/// Hive 缓存的持有者。
///
/// 之所以用一个静态单例而不是在 provider 里 `await` 打开盒子：
/// provider 的 build 不能是异步的，而 `Hive.openBox` 是异步的。
/// 用一个在 `main()` 里预先打开好的单例，provider 就能同步拿到实例。
///
/// **打开失败时降级为内存缓存**：缓存是锦上添花的东西，不是 App 启动的前提。
/// 因为它开不了就让整个 App 起不来，是本末倒置。内存缓存至少让
/// 「同一次运行内」的离线回退还能用。
class WorkCacheHolder {
  WorkCacheHolder._();

  static final WorkCacheHolder instance = WorkCacheHolder._();

  WorkCache? _cache;

  /// 打开真正的 Hive 缓存。`main()` 里在 `runApp` 之前调用。
  ///
  /// 返回 false 表示打开失败，已降级为内存缓存——App 仍能正常启动。
  Future<bool> initialize() async {
    if (_cache != null) return true;
    try {
      _cache = await HiveWorkCache.open();
      return true;
    } catch (_) {
      _cache = InMemoryWorkCache();
      return false;
    }
  }

  /// 给 provider 用的实例。未初始化时是内存缓存。
  WorkCache get cache => _cache ??= InMemoryWorkCache();
}

/// 作品缓存。
///
/// 降级策略与测试策略走的是**同一份实现**（都是 [WorkCache] 接口）：
/// 测试里验证的「缓存怎么读写」，与线上 Hive 的行为一致。
///
/// 想在测试里换实现：`workCacheProvider.overrideWithValue(InMemoryWorkCache())`。
final workCacheProvider = Provider<WorkCache>((ref) {
  return WorkCacheHolder.instance.cache;
});
