import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../data/models/collection_entry.dart';
import '../../data/repositories/collection_repository.dart';
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

/// 本人收藏列表。
///
/// 两个「自动」行为，都是为了少写清理代码：
/// - `watch` 当前 `user_id`：切账号/退出登录时自动重建，**不残留上一个账号的列表**（C6）；
/// - `watch` 筛选条件：换筛选自动重查。
class CollectionController extends AsyncNotifier<List<CollectionEntry>> {
  @override
  Future<List<CollectionEntry>> build() async {
    final userId = ref.watch(
      authControllerProvider.select((state) => state.user?.userId),
    );
    // 未登录不查：界面此时显示登录引导，而不是空列表 + 报错。
    if (userId == null) return const [];

    final status = ref.watch(collectionFilterProvider);
    return ref.watch(collectionRepositoryProvider).fetchAll(status: status);
  }

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

    try {
      final result = await ref
          .read(collectionRepositoryProvider)
          .updateStatus(workId, status);
      if (!ref.mounted) return null;

      // 以服务端返回的状态为准，不在本地推断「应该是这样」（C7）。
      // 但**只取状态**：响应里没有 title / work_type / cover_url，
      // 拿它替换整条会让列表显示成 work_id 或空标题。
      final filter = ref.read(collectionFilterProvider);
      state = AsyncData([
        for (final item in current)
          if (item.workId != workId)
            item
          else if (filter == null || result.status == filter)
            result.mergeInto(item),
      ]);
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

    try {
      await ref.read(collectionRepositoryProvider).remove(workId);
      if (!ref.mounted) return null;
      state = AsyncData(
        current.where((item) => item.workId != workId).toList(growable: false),
      );
      return null;
    } on ApiException catch (error) {
      return error;
    }
  }

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
    AsyncNotifierProvider<CollectionController, List<CollectionEntry>>(
      CollectionController.new,
      // 契约要求失败必须显式呈现，自动重试会让失败看起来像一直在加载。
      retry: (retryCount, error) => null,
    );
