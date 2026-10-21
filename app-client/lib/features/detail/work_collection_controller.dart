import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../data/models/collection_entry.dart';
import '../../data/models/collection_state.dart';
import '../../data/models/work.dart';
import '../../data/repositories/collection_repository.dart';
import '../auth/auth_controller.dart';
import '../collection/collection_controller.dart';

/// 单部作品的收藏状态（详情页用）。
///
/// 和收藏列表是两份数据：列表给的是「带作品字段的分页记录」，这条只回答
/// 「这部作品收了没有、什么状态」，响应里没有 `title` / `cover_url`，
/// 见 [CollectionState]。别拿它去替换列表里的整条记录。
///
/// 三条约束：
/// 1. `watch` 当前 `user_id`：切账号/退出后自动重查，**不继承上一个账号的状态**；
/// 2. 未登录**不发请求**（会 401），直接给「未收藏」，界面此时显示登录引导；
/// 3. 写操作以服务端返回为准，本地不猜，失败一律显式返回给页面提示（C7）。
class WorkCollectionController extends AsyncNotifier<CollectionState> {
  WorkCollectionController(this.workId);

  final String workId;

  @override
  Future<CollectionState> build() async {
    final userId = ref.watch(
      authControllerProvider.select((state) => state.user?.userId),
    );
    // 未收藏是正常返回值，不是错误——界面据此显示「收藏」按钮。
    if (userId == null) {
      return CollectionState(workId: workId, collected: false);
    }

    return ref.watch(collectionRepositoryProvider).fetchState(workId);
  }

  /// 收藏 ⇄ 取消收藏。返回 `null` 表示成功。
  ///
  /// 名字叫 toggle，但**落地的请求不是 toggle 接口**：收藏走一次 `PUT`、
  /// 取消走一次 `DELETE`，两个都是幂等的（计划 §5 第 4 条：服务端 toggle
  /// 碰上网络重试会把用户的操作反转回去）。这里只是根据当前状态选一个发。
  Future<ApiException?> toggle(Work work) async {
    // 仓储在第一个 await 之前取好：详情页被关掉时 provider 会被回收，
    // 之后再碰 `ref` 会抛「已释放」。写操作的寿命不该由页面生命周期决定。
    final repository = ref.read(collectionRepositoryProvider);
    final current = await _currentOrWait();
    if (!ref.mounted) return null;
    if (current == null) return _unknownStateError;
    return current.collected
        ? _remove(repository, work)
        : _add(repository, work);
  }

  /// 只收藏、不取消。登录回来之后接续用户刚才的动作时用它——
  /// 那时的点击意图是「收藏」，不是「切换」。
  Future<ApiException?> collect(Work work) async {
    final repository = ref.read(collectionRepositoryProvider);
    final current = await _currentOrWait();
    if (!ref.mounted) return null;
    if (current == null) return _unknownStateError;
    // 已经收藏了就什么都不做：PUT 是 upsert，盲发一次会把已有状态覆盖成 null。
    if (current.collected) return null;
    return _add(repository, work);
  }

  /// 改状态。**只改不建**（PATCH）：记录已不存在时服务端返回
  /// `COLLECTION_REQUIRED`，客户端不得顺手补一个 PUT（C11）。
  Future<ApiException?> setStatus(CollectionStatus? status) async {
    final repository = ref.read(collectionRepositoryProvider);
    try {
      final remote = await repository.updateStatus(workId, status);
      return _apply(remote);
    } on ApiException catch (error) {
      return _fail(error);
    }
  }

  /// 当前状态。还没查到（首帧）或上次查询失败时，先等一次真实结果——
  /// 在「不知道现在有没有收藏」的前提下做切换，等于猜。
  Future<CollectionState?> _currentOrWait() async {
    final value = state.value;
    if (value != null) return value;
    try {
      return await future;
    } on Object {
      return null;
    }
  }

  Future<ApiException?> _add(CollectionRepository repository, Work work) async {
    try {
      final remote = await repository.add(work.workId);
      return _apply(remote);
    } on ApiException catch (error) {
      return _fail(error);
    }
  }

  Future<ApiException?> _remove(
    CollectionRepository repository,
    Work work,
  ) async {
    try {
      await repository.remove(work.workId);
      if (!ref.mounted) return null;
      final now = DateTime.now().toUtc();
      state = AsyncData(
        CollectionState(workId: workId, collected: false, updatedAt: now),
      );
      _invalidateList();
      return null;
    } on ApiException catch (error) {
      return _fail(error);
    }
  }

  /// 写成功：状态以服务端返回为准，同时让收藏页的列表缓存失效。
  ///
  /// 为什么不是本地改列表：列表项的 `title` / `work_type` / `cover_url`
  /// 写接口都不返回，在本地拼一条会和详情页、服务端各说一套；让列表下次被
  /// 读到时重新拉一次，代价只有一次请求。
  ApiException? _apply(CollectionState remote) {
    if (!ref.mounted) return null;
    state = AsyncData(remote);
    _invalidateList();
    return null;
  }

  ApiException? _fail(ApiException error) {
    if (!ref.mounted) return error;
    // 409 说明本地这份状态已经过期（别处删了收藏），重新查一次再让用户操作。
    if (error.code == ApiErrorCode.collectionRequired) {
      ref.invalidateSelf();
    }
    return error;
  }

  void _invalidateList() {
    ref.invalidate(collectionControllerProvider);
  }

  static const ApiException _unknownStateError = ApiException(
    code: ApiErrorCode.unknown,
    message: '收藏状态还没拿到，请稍后重试',
  );
}

/// 详情页按作品 ID 取收藏状态。
///
/// `autoDispose`：离开详情页就释放，不在进程里按访问过的作品无限累积；
/// 重新进来会重查一次，跨端改过收藏也能立刻看到。
final workCollectionProvider = AsyncNotifierProvider.autoDispose
    .family<WorkCollectionController, CollectionState, String>(
      WorkCollectionController.new,
      // 失败必须显式呈现，自动重试会让「接口挂了」看起来像一直在加载。
      retry: (retryCount, error) => null,
    );
