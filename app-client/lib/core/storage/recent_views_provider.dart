import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'hive_recent_views_store.dart';
import 'memory_recent_views_store.dart';
import 'recent_views_store.dart';

/// 浏览历史的持有者。
///
/// 与 `WorkCacheHolder` / `CollectionCacheHolder` 同一个理由：provider 的
/// build 不能是异步的，而 `Hive.openBox` 是异步的。在 `main()` 里预先打开，
/// 之后 provider 同步拿实例——历史是首页第一屏的内容，晚一帧就会出现
/// 「区块先空着、随后突然冒出来」的跳动。
///
/// **打开失败降级为内存实现**：历史不该成为 App 启动的前提。
class RecentViewsHolder {
  RecentViewsHolder._();

  static final RecentViewsHolder instance = RecentViewsHolder._();

  RecentViewsStore? _store;

  /// 打开真正的 Hive 存储。`main()` 里在 `runApp` 之前调用。
  ///
  /// 返回 false 表示已降级为内存实现。
  Future<bool> initialize() async {
    if (_store != null) return true;
    try {
      _store = await HiveRecentViewsStore.open();
      return true;
    } catch (_) {
      _store = InMemoryRecentViewsStore();
      return false;
    }
  }

  /// 给 provider 用的实例。未初始化时是内存实现。
  RecentViewsStore get store => _store ??= InMemoryRecentViewsStore();
}

/// 浏览历史的存储。
///
/// 测试里换成内存实现：
/// `recentViewsStoreProvider.overrideWithValue(InMemoryRecentViewsStore())`。
final recentViewsStoreProvider = Provider<RecentViewsStore>((ref) {
  return RecentViewsHolder.instance.store;
});
