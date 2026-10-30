import 'package:dio/dio.dart';

import '../models/remote_config.dart';
import 'app_config_data_source.dart';

/// `GET /api/app/config`。
///
/// 失败**不抛给界面**：配置是"锦上添花"的东西（公告、开关），拿不到就用本机缓存 / 空配置，
/// 不能让一次配置请求超时把首页拖成错误态。所以这里吞掉异常返回空配置，
/// 由调用方决定是否保留旧快照。
class RemoteAppConfigDataSource implements AppConfigDataSource {
  RemoteAppConfigDataSource(this._dio);

  final Dio _dio;

  static const String _path = '/api/app/config';

  @override
  Future<RemoteConfig> fetch() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(_path);
      final data = response.data;
      if (data == null) {
        return RemoteConfig.empty;
      }
      return RemoteConfig.fromJson(data);
    } on DioException {
      return RemoteConfig.empty;
    }
  }
}
