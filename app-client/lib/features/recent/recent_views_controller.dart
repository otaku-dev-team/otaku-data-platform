import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/recent_views_provider.dart';
import '../../data/models/recent_view.dart';
import '../../data/models/work.dart';
import '../auth/auth_controller.dart';

/// 最近浏览。**纯本地**：不经过后端，也不挂在 `WorkCache` 上。
///
/// 四个刻意的取舍：
///
/// 1. **按账号分桶**。历史会暴露「这台机器上看过什么」，换个人登录不该看见
///    上一个人的口味——和收藏缓存同一个理由。未登录写进 `guest` 桶，因此
///    「先随便看看再登录」的那段历史不会跟过去。宁可少一条，不要串号。
/// 2. **退出登录不清**。收藏是服务端数据的副本，清掉还能拉回来；浏览历史
///    只存在于本机，清了就真没了。数据本来就按账号分键，第二个人读不到。
/// 3. **同一作品只留一条，且置顶**。再次打开是「换时间 + 挪到最前」，
///    不是「再来一条」——否则横排里会出现同一部作品的两张卡。
/// 4. **上限 50 条**，环形裁剪。首页那条横排就是全部，不设"查看全部"页。
///
/// 记录时机由详情页负责（拿到数据才算看过，失败与 404 都不记）。
class RecentViewsController extends Notifier<List<RecentView>> {
  /// 最多记多少条。够覆盖「这一阵看过什么」，再长也没人会横向翻到底。
  static const int maxEntries = 50;

  /// 未登录时的桶名。真实账号 id 不会是它（后端生成，形如不透明串）。
  static const String guestOwner = 'guest';

  @override
  List<RecentView> build() {
    // watch 账号：登录 / 退出 / 换号时自动换桶，不残留上一个人的列表。
    return ref.watch(recentViewsStoreProvider).read(_ownerOf(ref));
  }

  static String _ownerOf(Ref ref) =>
      ref.watch(authControllerProvider.select((state) => state.user?.userId)) ??
      guestOwner;

  /// 记一次浏览。`at` 只给测试用，生产走当前时间。
  void record(Work work, {DateTime? at}) {
    final entry = RecentView.of(work, viewedAt: at);
    final next = <RecentView>[
      entry,
      for (final item in state)
        if (item.workId != entry.workId) item,
    ];
    if (next.length > maxEntries) next.removeRange(maxEntries, next.length);
    _commit(next);
  }

  /// 清空当前账号的历史。
  void clear() => _commit(const <RecentView>[]);

  void _commit(List<RecentView> next) {
    final items = List<RecentView>.unmodifiable(next);
    state = items;

    final owner = ref.read(
      authControllerProvider.select((state) => state.user?.userId),
    );
    // 落盘不 await：内存里已经是最终状态，界面不用等磁盘。
    // 写失败最多让下次启动少一条记录，不值得把首页卡在一个 Future 上。
    unawaited(
      ref.read(recentViewsStoreProvider).write(owner ?? guestOwner, items),
    );
  }
}

final recentViewsProvider =
    NotifierProvider<RecentViewsController, List<RecentView>>(
      RecentViewsController.new,
    );
