import '../../data/models/recent_view.dart';
import 'recent_views_store.dart';

/// 内存版浏览历史。
///
/// 两个用途：Hive 打开失败时的降级（历史是锦上添花，不能拖垮启动），
/// 以及测试里替换真实实现——与 `InMemoryWorkCache` 同一个理由。
class InMemoryRecentViewsStore implements RecentViewsStore {
  final Map<String, List<RecentView>> _byOwner = {};

  @override
  List<RecentView> read(String ownerKey) {
    final items = _byOwner[ownerKey];
    return items == null
        ? const <RecentView>[]
        : List<RecentView>.unmodifiable(items);
  }

  @override
  Future<void> write(String ownerKey, List<RecentView> items) async {
    _byOwner[ownerKey] = List<RecentView>.of(items);
  }

  @override
  Future<void> clear(String ownerKey) async {
    _byOwner.remove(ownerKey);
  }
}
