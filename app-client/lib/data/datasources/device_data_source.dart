import '../models/device.dart';

/// 本账号已登记的推送设备。
///
/// 契约见 `docs/openapi.yaml` 的 `/api/me/devices*`。两条语义写死在实现里：
/// 1. 列表**按 `created_at DESC`**（服务端保证），客户端不再排一次；
/// 2. [revoke] 幂等——记录不存在也返回 `204`，所以不用先查一次。
///
/// 注意：这里只管「已登记设备」，不管推送令牌的登记/刷新（那是
/// `POST /api/me/devices`，属推送链路，本期不接）。
abstract class DeviceDataSource {
  Future<List<Device>> fetchAll();

  /// 解绑一台设备。幂等，删失败由调用方决定是否提示（登出时不阻断）。
  Future<void> revoke(String deviceId);
}
