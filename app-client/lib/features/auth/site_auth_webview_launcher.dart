import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/router/app_router.dart';
import '../../core/router/route_paths.dart';
import 'site_auth_launcher.dart';
import 'site_auth_webview_page.dart';

/// 用 App 内 WebView 承载站点授权页的 [SiteAuthLauncher]。
///
/// **为什么不走系统浏览器**：`docs/app-registration-approach.md` §3 的形态是
/// 「注册与授权在同一个 WebView 里」。系统浏览器的 cookie 域与 WebView 是两套，
/// 在 WebView 里注册完再去浏览器 authorize，站点不认这个登录态，
/// 「注册完直接就是登录态」的承诺就落空了。所以这里主动放弃 RFC 8252 的
/// 「必须外部用户代理」约束，换取单次登录闭环——**代价与边界写在
/// [SiteAuthLauncher] 的类注释里**，改动前先读那一段。
///
/// 能用的前提（任一不满足就 [supported] = false，登录页据此隐藏入口）：
/// - 平台必须有 WebView 实现（Android / iOS）；
/// - 构建期必须注入 `SITE_BASE_URL`（站点地址，不是平台 API 地址）。
class WebViewSiteAuthLauncher implements SiteAuthLauncher {
  WebViewSiteAuthLauncher(this._ref) {
    _ref.onDispose(_redirects.close);
  }

  final Ref _ref;
  final StreamController<String> _redirects =
      StreamController<String>.broadcast();

  static const Set<TargetPlatform> _platformsWithWebView = {
    TargetPlatform.android,
    TargetPlatform.iOS,
  };

  @override
  bool get supported =>
      !kIsWeb &&
      _platformsWithWebView.contains(defaultTargetPlatform) &&
      AppConfig.siteBaseUrl.isNotEmpty;

  @override
  Stream<String> get redirects => _redirects.stream;

  @override
  Future<bool> openAuthorize({required String state}) async {
    if (!supported) return false;
    try {
      _ref.read(appRouterProvider).push(
            RoutePaths.siteAuth,
            extra: SiteAuthWebViewArgs(
              state: state,
              onRedirect: _deliver,
            ),
          );
      return true;
    } on Object {
      // 推路由失败（路由未注册 / 框架状态异常）时返回 false，
      // 由 AuthController 统一呈现「打不开授权页面」，不要静默吞掉。
      return false;
    }
  }

  void _deliver(String uri) {
    if (_redirects.isClosed) return;
    _redirects.add(uri);
  }
}
