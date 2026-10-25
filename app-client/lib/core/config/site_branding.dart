import 'app_config.dart';

/// 站点品牌配置（定位 §7.2 产品要求 2：「每站一个独立客户端、品牌归属网站」）。
///
/// **品牌资源分两类，混在一起谈就会做出错误的设计**：
///
/// - **运行时可定**：应用内显示的应用名、桌面窗口标题。改这里立刻见效。
/// - **只能构建期定**：Android `applicationId` 与 app label、桌面包标识与公司名、
///   图标资源。这些是系统级身份——Launcher 会缓存 label 与图标，
///   `applicationId` 更是系统里这台设备的「我是谁」，运行时改只会让下次启动
///   认不出自己。
///
/// 所以「按站点区分品牌」= **一份构建期注入的品牌配置**，不是运行时切换。
/// 注入走 `--dart-define`，见 [`docs/site-branding.md`](../../../../docs/site-branding.md)。
///
/// 默认值即首站（otaku_site）现状：不传任何 define 时，行为与之前完全一致。
abstract final class SiteBranding {
  const SiteBranding._();

  /// 应用名。Android app label、桌面窗口标题、关于页都用它。
  static const String _appName = String.fromEnvironment(
    'APP_NAME',
    defaultValue: 'Otaku',
  );

  /// 品牌归属方（公司 / 站点主体）。桌面窗口的公司名与版权行用它。
  static const String _company = String.fromEnvironment(
    'BRAND_COMPANY',
    defaultValue: 'com.otaku',
  );

  /// 站点标识。与 [AppConfig.siteId] 同源——换站时两个一起换，
  /// 分裂成两个来源就会出现「关于页显示 A、请求带 B」。
  static String get siteId => AppConfig.siteId;

  static String get appName => _appName.trim().isEmpty ? 'Otaku' : _appName.trim();

  static String get company =>
      _company.trim().isEmpty ? 'com.otaku' : _company.trim();

  /// 桌面窗口标题。带站点标识，多开时能从任务栏分清是哪个站的客户端。
  static String get windowTitle => '$appName · $siteId';

  /// 版权行（桌面关于窗 / Runner.rc 的文案模板）。
  static String get copyright => '© ${DateTime.now().year} $company';
}
