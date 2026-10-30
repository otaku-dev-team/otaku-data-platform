import '../models/remote_config.dart';

/// 运行期配置的数据来源。真接口与空实现各一份。
///
/// 只做一次 GET，没有参数：配置条目只有个位数，按 key 查等于把一次请求拆成 N 次。
abstract interface class AppConfigDataSource {
  Future<RemoteConfig> fetch();
}
