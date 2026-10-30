import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../data/models/collection_entry.dart';
import '../../data/repositories/collection_repository.dart';
import '../../data/repositories/work_repository.dart' show Fetched;
import '../auth/auth_controller.dart';

/// 收藏页的状态筛选。`null` = 全部（含「已收藏但未设状态」）。
class CollectionFilterController extends Notifier<CollectionStatus?> {
  @override
  CollectionStatus? build() => null;

  void select(CollectionStatus? status) {
    if (state == status) return;
    state = status;
  }
}

final collectionFilterProvider =
    NotifierProvider<CollectionFilterController, CollectionStatus?>(
      CollectionFilterController.new,
    );

/// 离线时写操作一律拒掉。
///
/// 界面上这份数据是缓存的，改动**发不出去**，发出去也只会超时。与其让用户
/// 等一个必然失败的请求，不如立刻说清楚。
///
/// 而且**不能**在本地改完假装成功：收藏是跨端同步的，本地改了没同步，
/// 用户会以为手机上也改好了——那是比「改不动」更糟的错觉。
const ApiException collectionOfflineReadOnly = ApiException(
  code: ApiErrorCode.unknown,
  message: '当前离线，收藏只能查看；恢复网络后再修改',
);

/// 本人收藏列表。
///
/// 两个「自动」行为，都是为了少写清理代码：
/// - `watch` 当前 `user_id`：切账号/退出登录时自动重建，**不残留上一个账号的列表**（C6）；
/// - `watch` 筛选条件：换筛选自动重查。
///
/// 状态里带 [Fetched] 是为了让界面能说清「这是缓存」——离线只读的前提下，
/// 用户看到的可能不是最新数据，不标注就是让人基于过期信息做判断。
class CollectionController
    extends AsyncNotifier<Fetched<List<CollectionEntry>>> {
  @override
  Future<Fetched<List<CollectionEntry>>> build() async {
    final userId = ref.watch(
      authControllerProvider.select((state) => state.user?.userId),
    );
    // 未登录不查：界面此时显示登录引导，而不是空列表 + 报错。
    if (userId == null) return const Fetched.live(<CollectionEntry>[]);

    final status = ref.watch(collectionFilterProvider);
    return ref
        .watch(collectionRepositoryProvider)
        .fetchAll(userId: userId, status: status);
  }

  /// 当前登录账号。写缓存要用到；没了就不该继续改。
  String? get _userId =>
      ref.read(authControllerProvider.select((state) => state.user?.userId));

  /// 改状态。**只改不建**——记录已不存在时（C11）返回 `COLLECTION_REQUIRED`，
  /// 同时重新拉列表，让界面和后端对齐。
  ///
  /// 返回 `null` 表示成功；返回异常表示失败，由页面提示。
  Future<ApiException?> changeStatus(
    String workId,
    CollectionStatus? status,
  ) async {
    final current = state.value;
    if (current == null) return null;
    if (current.fromCache) return collectionOfflineReadOnly;

    final userId = _userId;
    if (userId == null) return null;

    try {
      final result = await ref
          .read(collectionRepositoryProvider)
          .updateStatus(workId, status);
      if (!ref.mounted) return null;

      // 以服务端返回的状态为准，不在本地推断「应该是这样」（C7）。
      // 但**只取状态**：响应里没有 title / work_type / cover_url，
      // 拿它替换整条会让列表显示成 work_id 或空标题。
      final filter = ref.read(collectionFilterProvider);
      final next = <CollectionEntry>[
        for (final item in current.value)
          if (item.workId != workId)
            item
          else if (filter == null || result.status == filter)
            result.mergeInto(item),
      ];
      state = AsyncData(Fetched.live(next));
      await _remember(userId, next, filter);
      return null;
    } on ApiException catch (error) {
      if (!ref.mounted) return error;
      if (error.code == ApiErrorCode.collectionRequired) {
        ref.invalidateSelf();
      }
      return error;
    }
  }

  Future<ApiException?> remove(String workId) async {
    final current = state.value;
    if (current == null) return null;
    if (current.fromCache) return collectionOfflineReadOnly;

    final userId = _userId;
    if (userId == null) return null;

    try {
      await ref.read(collectionRepositoryProvider).remove(workId);
      if (!ref.mounted) return null;
      final next = current.value
          .where((item) => item.workId != workId)
          .toList(growable: false);
      state = AsyncData(Fetched.live(next));
      await _remember(userId, next, ref.read(collectionFilterProvider));
      return null;
    } on ApiException catch (error) {
      return error;
    }
  }

  /// 把服务端确认过的列表写回缓存，让离线时看到的是这一版。
  Future<void> _remember(
    String userId,
    List<CollectionEntry> entries,
    CollectionStatus? filter,
  ) => ref
      .read(collectionRepositoryProvider)
      .remember(userId, entries, status: filter);

  Future<void> refresh() async {
    ref.invalidateSelf();
    try {
      await future;
    } on Object {
      // 忽略：错误已经进 AsyncError，由页面呈现。
    }
  }
}

final collectionControllerProvider =
    AsyncNotifierProvider<CollectionController, Fetched<List<CollectionEntry>>>(
      CollectionController.new,
      // 契约要求失败必须显式呈现，自动重试会让失败看起来像一直在加载。
      retry: (retryCount, error) => null,
    );
