import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/network/dio_client.dart';
import '../datasources/device_data_source.dart';
import '../datasources/device_mock_data_source.dart';
import '../datasources/device_remote_data_source.dart';

/// 设备列表的数据源。默认 Mock；联调时加 `--dart-define=USE_MOCK=false` 切真实接口。
///
/// 这里**没有 repository 层**：设备列表没有缓存、没有跨源合并、没有业务规则，
/// 加一层只会在 controller 和 data source 之间多一次转发。等真出现「离线看设备」
/// 这种需求再补，那时要改的是 controller 的依赖，页面不用动。
final deviceDataSourceProvider = Provider<DeviceDataSource>((ref) {
  if (AppConfig.useMock) return MockDeviceDataSource();
  return RemoteDeviceDataSource(ref.watch(dioProvider));
});
