import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../data/models/device.dart';
import '../../data/repositories/device_repository.dart';
import '../auth/auth_controller.dart';

/// 已登记设备列表。
///
/// `watch` 当前 `user_id`：切账号 / 退出登录时自动重建，**不残留上一个账号的设备**
/// （与收藏按账号隔离同一个理由——推送停在锁屏上的后果比列表串号更直接）。
///
/// 未登录返回空列表而不是抛错：页面此时显示登录引导，空列表 + 报错会变成两张脸。
class DeviceListController extends AsyncNotifier<List<Device>> {
  @override
  Future<List<Device>> build() async {
    final userId = ref.watch(
      authControllerProvider.select((state) => state.user?.userId),
    );
    if (userId == null) return const <Device>[];

    return ref.watch(deviceDataSourceProvider).fetchAll();
  }

  /// 解绑一台设备。返回 `null` 表示成功，否则返回异常由页面提示。
  ///
  /// 成功后**先本地移除再刷新**：解绑是用户主动动作，列表立刻少一行比转圈等
  /// 服务端回包更符合预期；万一服务端其实没删掉，下一次刷新会把它带回来。
  Future<ApiException?> revoke(String deviceId) async {
    final current = state.value;
    if (current == null) return null;

    try {
      await ref.read(deviceDataSourceProvider).revoke(deviceId);
    } on ApiException catch (error) {
      return error;
    } on Object {
      return const ApiException(
        code: ApiErrorCode.unknown,
        message: '解绑失败，请稍后重试',
      );
    }

    state = AsyncData(
      List<Device>.unmodifiable(
        current.where((device) => device.deviceId != deviceId),
      ),
    );
    return null;
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

final deviceListControllerProvider =
    AsyncNotifierProvider<DeviceListController, List<Device>>(
      DeviceListController.new,
      // 契约要求失败必须显式呈现，自动重试会让失败看起来像一直在加载。
      retry: (retryCount, error) => null,
    );
