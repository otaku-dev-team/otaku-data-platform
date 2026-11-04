import 'package:dio/dio.dart';

import '../../core/network/api_exception.dart';
import '../models/device.dart';
import 'device_data_source.dart';

/// 真实的设备列表实现。契约见 `docs/openapi.yaml` 的 `/api/me/devices*`。
class RemoteDeviceDataSource implements DeviceDataSource {
  RemoteDeviceDataSource(this._dio);

  final Dio _dio;

  static const String _path = '/api/me/devices';

  static String _itemPath(String deviceId) =>
      '$_path/${Uri.encodeComponent(deviceId)}';

  @override
  Future<List<Device>> fetchAll() async {
    // 契约的 200 是**数组**，不是分页对象——设备上限 10 台，没有分页的必要。
    final response = await _call(() => _dio.get<List<dynamic>>(_path));
    final data = response.data;
    if (data == null) return const <Device>[];

    final devices = <Device>[];
    for (final item in data) {
      if (item is! Map<String, dynamic>) continue;
      try {
        devices.add(Device.fromJson(item));
      } on FormatException {
        // 单条解析失败跳过，不让一条脏数据拖垮整页。
        continue;
      }
    }
    return List<Device>.unmodifiable(devices);
  }

  @override
  Future<void> revoke(String deviceId) async {
    // 幂等：本来就没登记也返回 204，所以不需要先查一次。
    await _call(() => _dio.delete<void>(_itemPath(deviceId)));
  }

  static Future<T> _call<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on DioException catch (error) {
      throw ApiException.fromDio(error);
    }
  }
}
