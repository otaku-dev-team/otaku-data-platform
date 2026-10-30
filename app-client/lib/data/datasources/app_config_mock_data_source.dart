import '../models/remote_config.dart';
import 'app_config_data_source.dart';

/// Mock 模式下的配置来源：**不发任何请求**，返回空配置。
///
/// 为什么不是"返回一份假公告"：widget 测试会跑在所有页面上，默认弹一条公告
/// 会让每个用例都要额外处理它；要测公告的用例自己 override 数据源即可。
class MockAppConfigDataSource implements AppConfigDataSource {
  const MockAppConfigDataSource();

  @override
  Future<RemoteConfig> fetch() async => RemoteConfig.empty;
}
