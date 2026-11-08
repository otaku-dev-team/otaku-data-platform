import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/collection_entry.dart';
import '../../data/repositories/collection_repository.dart';
import '../auth/auth_controller.dart';

/// 个人空间顶部统计带的数字。
///
/// 三个数都可能是 `null`：未登录、还在拉、拉失败了。**不用 0 顶替**——
/// 「0 条收藏」和「不知道几条」对用户是两件事，写死 0 会让人以为收藏丢了。
/// 界面据此显示「—」，等数据到了再变成数字。
@immutable
class ProfileStats {
  const ProfileStats({this.collected, this.watched, this.wanted});

  /// 收藏总数（含未标注状态的）。
  final int? collected;

  /// 标成「看过」的条数。
  final int? watched;

  /// 标成「想看」的条数。
  final int? wanted;
}

/// 统计口径：拉一次**不带筛选**的收藏列表，本地数三种状态。
///
/// 为什么不复用 `collectionControllerProvider`：它跟着收藏页的筛选走，
/// 用户在收藏页选了「看过」之后，这里就会把 3 条当成全部。统计要的是全集，
/// 跟当前在看哪一屏无关。
///
/// 独立于收藏页的另一个好处：本页刷新不会把收藏页的筛选重置掉。
final profileStatsProvider = FutureProvider.autoDispose<ProfileStats>((
  ref,
) async {
  final userId = ref.watch(
    authControllerProvider.select((state) => state.user?.userId),
  );
  // 未登录不查：收藏是账号数据，此时界面显示登录引导而不是「0 条」。
  if (userId == null) return const ProfileStats();

  final fetched = await ref
      .watch(collectionRepositoryProvider)
      .fetchAll(userId: userId);

  var watched = 0;
  var wanted = 0;
  for (final item in fetched.value) {
    switch (item.status) {
      case CollectionStatus.watched:
        watched++;
      case CollectionStatus.want:
        wanted++;
      // 抛弃计入「收藏总数」（记录还在，收藏页的「全部」也含它），
      // 但既不算看过也不算想看——它是「我不看了」（#496）。
      case CollectionStatus.watching:
      case CollectionStatus.dropped:
      case null:
        break;
    }
  }
  return ProfileStats(
    collected: fetched.value.length,
    watched: watched,
    wanted: wanted,
  );
  // 契约要求失败显式呈现：自动重试会让失败看起来像一直在加载。
}, retry: (retryCount, error) => null);
