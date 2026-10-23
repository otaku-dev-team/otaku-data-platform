import 'package:flutter/foundation.dart';

import '../../data/models/collection_entry.dart';
import 'work_cache.dart' show CachedEntry;

/// 收藏列表的缓存键。
///
/// **账号是第一维度，不是可选项**：收藏是「本人」的数据，A 的收藏绝不能
/// 出现在 B 的界面上。少了 `userId`，「A 用完退出 → B 登录 → B 恰好离线」
/// 时，B 会看到 A 的收藏列表，而界面上完全看不出异常——这和
/// `ListCacheKey` 漏掉 `tag` 是同一类 bug，但后果是隐私事故而不是内容错位。
///
/// 状态筛选同样进键：「全部」与「只看想看」是两次不同的请求，共用一个键
/// 会让切到「想看」时拿到没筛过的整份列表。
@immutable
class CollectionCacheKey {
  const CollectionCacheKey({required this.userId, this.status});

  /// 当前登录账号。退出登录后不会再有人用旧 id 来读，见 [CollectionCache.clearUser]。
  final String userId;

  /// 状态筛选。`null` = 全部。
  final CollectionStatus? status;

  /// 拼成缓存的键。分隔符用 `\u0000`（正常文本里不会出现）。
  String get storageKey {
    final parts = [userId, status?.value ?? ''];
    return 'collection:${parts.join('\u0000')}';
  }

  @override
  bool operator ==(Object other) =>
      other is CollectionCacheKey &&
      other.userId == userId &&
      other.status == status;

  @override
  int get hashCode => Object.hash(userId, status);

  @override
  String toString() => 'CollectionCacheKey($storageKey)';
}

/// 收藏列表的本地缓存。
///
/// 与 [WorkCache] 分开成两个接口，是因为两者的**生命周期不同**：
/// 作品缓存是公共数据，换账号照样能看；收藏是私人数据，**换账号就必须换一批**。
/// 混在一个接口里，迟早会有人在写作品缓存时忘了带账号维度。
///
/// 同样只缓存「平台（Java）已返回」的响应——铁律 1。
abstract interface class CollectionCache {
  /// 读缓存。没有缓存返回 `null`。
  Future<CachedEntry<List<CollectionEntry>>?> read(CollectionCacheKey key);

  /// 写缓存。
  Future<void> write(CollectionCacheKey key, List<CollectionEntry> entries);

  /// 只清某个账号的缓存。**退出登录时调用**——缓存里是这个人看过的内容，
  /// 留到下一个人登录（哪怕读不到）也不合适。
  Future<void> clearUser(String userId);

  /// 清空全部缓存。
  Future<void> clear();
}
