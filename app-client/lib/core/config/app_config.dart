import 'dart:io';

/// 运行期配置。所有可变项集中在这里，避免魔法值散落到各层。
///
/// 构建期覆盖：
/// ```
/// flutter run -d windows --dart-define=USE_MOCK=false --dart-define=API_BASE_URL=http://127.0.0.1:8080
/// ```
abstract final class AppConfig {
  const AppConfig._();

  static const String _baseUrlOverride = String.fromEnvironment('API_BASE_URL');

  /// 真接口未就绪时走 Mock 数据源。默认 true，联调时用 --dart-define 关掉。
  static const bool useMock = bool.fromEnvironment('USE_MOCK', defaultValue: true);

  /// 契约 6.1：`page_size` 默认 20、上限 50，超了服务端截断不报错。
  static const int pageSize = 20;
  static const int maxPageSize = 50;

  /// 第一阶段单站点。只用于日志与 Mock，**请求不带站点参数**（契约第 9 节）。
  static const String siteId = 'otaku_site';

  /// 后端地址。Android 模拟器访问宿主机必须用 10.0.2.2，不能用 127.0.0.1。
  static String get baseUrl {
    if (_baseUrlOverride.isNotEmpty) return _baseUrlOverride;
    return Platform.isAndroid ? 'http://10.0.2.2:8080' : 'http://127.0.0.1:8080';
  }
}
