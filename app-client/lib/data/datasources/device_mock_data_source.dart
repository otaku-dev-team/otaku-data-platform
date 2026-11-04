import '../models/device.dart';
import 'device_data_source.dart';

/// 骨架阶段的设备列表：内存里放三台，解绑即时生效。
///
/// Mock 只保证「页面有东西可看、解绑有反馈」，不模拟服务端的真实约束
/// （每账号最多 10 台、token 跨账号转移）。那些要靠真接口验证。
class MockDeviceDataSource implements DeviceDataSource {
  final List<Device> _devices = [
    Device(
      deviceId: 'mock-this-device',
      platform: 'android',
      provider: 'fcm',
      enabled: true,
      createdAt: DateTime(2026, 11, 1, 9, 30),
      updatedAt: DateTime(2026, 11, 4, 22, 10),
    ),
    Device(
      deviceId: 'mock-desktop',
      platform: 'windows',
      provider: 'fcm',
      enabled: true,
      createdAt: DateTime(2026, 10, 20, 20, 5),
      updatedAt: DateTime(2026, 11, 2, 8, 0),
    ),
    Device(
      deviceId: 'mock-old-phone',
      platform: 'android',
      provider: 'fcm',
      enabled: false,
      createdAt: DateTime(2026, 9, 12, 14, 0),
      updatedAt: DateTime(2026, 10, 1, 11, 20),
    ),
  ];

  @override
  Future<List<Device>> fetchAll() async {
    // 与服务端一致：`created_at DESC`。
    final sorted = [..._devices]
      ..sort((a, b) {
        final at = a.createdAt;
        final bt = b.createdAt;
        if (at == null && bt == null) return 0;
        if (at == null) return 1;
        if (bt == null) return -1;
        return bt.compareTo(at);
      });
    return List<Device>.unmodifiable(sorted);
  }

  @override
  Future<void> revoke(String deviceId) async {
    _devices.removeWhere((device) => device.deviceId == deviceId);
  }
}
