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

  /// 契约 6.1：`page_size` 上限 50，超了服务端按 50 截断，不报错。
  static const int maxPageSize = 50;

  /// 每页请求条数。取契约上限，不用默认值 20。
  ///
  /// 依据是阶段 3 的基线实测（`docs/stage3-performance-baseline.md`）：1 万条下渲染
  /// jank 0%、build p50 0.46ms，单次请求 5.8–10.1ms，代价全在**页数**上——
  /// 20 条一页看完 1 万条要 500 次串行请求，50 条则是 200 次。
  static const int pageSize = maxPageSize;

  /// 应用版本，设置页「关于」里显示。
  ///
  /// 由 `build_site.sh --version-name` 在构建期注入；缺省值与 `pubspec.yaml` 对齐。
  /// 远程更新必须拿到**数字** versionCode 才能比较新旧，所以它和展示用的
  /// [versionName] 分开：前者每次发版递增，后者给人看。
  static const String versionName = String.fromEnvironment(
    'APP_VERSION_NAME',
    defaultValue: '1.0.0',
  );

  static const int versionCode = int.fromEnvironment(
    'APP_VERSION_CODE',
    defaultValue: 1,
  );

  /// 兼容旧调用：设置页只关心展示串。
  static const String version = versionName;

  /// 更新清单与安装包的基地址。
  ///
  /// 生产环境 nginx 与 API 同域，默认 `${baseUrl}/downloads` 即可；联调环境
  /// API 直连 8080、nginx 在 80/443，构建时要显式注入：
  /// `--dart-define=UPDATE_BASE_URL=http://154.8.194.198/downloads`。
  static const String _updateBaseUrlOverride = String.fromEnvironment(
    'UPDATE_BASE_URL',
  );

  static String get updateBaseUrl {
    if (_updateBaseUrlOverride.isNotEmpty) return _updateBaseUrlOverride;
    return '$baseUrl/downloads';
  }

  /// 后端地址。Android 模拟器访问宿主机必须用 10.0.2.2，不能用 127.0.0.1。
  static String get baseUrl {
    if (_baseUrlOverride.isNotEmpty) return _baseUrlOverride;
    return Platform.isAndroid ? 'http://10.0.2.2:8080' : 'http://127.0.0.1:8080';
  }

  /// **来源站**地址（不是平台后端）。用于 App 内 WebView 承载站点登录 / 注册页。
  ///
  /// 与 [baseUrl] 是两件事：`baseUrl` 是我们自己的 `/api/**`，这个地址是网站的
  /// HTML 页面（`/oauth/authorize`、`/login`、`/register`）。混用会把授权页
  /// 打到平台后端上，得到一个 404 的空白 WebView。
  ///
  /// 空字符串 = 未配置 = 站点授权入口不可用（登录页隐藏它，不置灰）。
  /// 由 `sites/<site>/site.conf` 的 `SITE_BASE_URL` 在构建期注入，见 `build_site.sh`。
  static const String siteBaseUrl = String.fromEnvironment('SITE_BASE_URL');
}
