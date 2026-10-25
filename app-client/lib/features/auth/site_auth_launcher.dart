import 'dart:async';

/// 站点授权的「打开浏览器」与「接回调」两端。
///
/// 为什么抽象出来：授权链路一半在 App 外（系统浏览器），一半在 App 内
/// （scheme 回跳）。把这两端各自收成接口，业务层才能在不真开浏览器的情况下
/// 被完整测试——深链接、进程回收、state 过期这些都是单元测试该覆盖的，
/// 不该等到真机上九点钟才发现。
abstract interface class SiteAuthLauncher {
  /// 这台设备能不能走授权流程。
  ///
  /// 桌面端这一轮是 false（loopback 回调端口未进站点白名单，见
  /// `docs/w1-login-dual-entry.md` §2.6）。界面据此**整块隐藏**入口，
  /// 而不是置灰——不给用户点了没反应的按钮。
  bool get supported;

  /// 回跳 URI 流。每个 URI 形如 `com.otaku.app:/oauth2redirect?ticket=…&state=…`。
  Stream<String> get redirects;

  /// 打开系统浏览器的授权页。返回是否成功调起。
  ///
  /// **必须是系统浏览器，不能是 App 内 WebView**：用户要能从地址栏确认域名，
  /// App 也不该接触站点登录页（RFC 8252）。
  Future<bool> openAuthorize({required String state});
}

/// 开发 / 测试用的假实现。
///
/// 不真的开浏览器，`supported` 恒 true——这样桌面走查与 widget 测试
/// 能把双入口与整条授权流程跑完，不必等联调环境。
/// [simulateRedirect] 就是给它们用的：代替浏览器把回跳 URI 喂进来。
class MockSiteAuthLauncher implements SiteAuthLauncher {
  MockSiteAuthLauncher();

  final StreamController<String> _redirects =
      StreamController<String>.broadcast();

  int openCalls = 0;
  String? lastState;

  @override
  bool get supported => true;

  @override
  Stream<String> get redirects => _redirects.stream;

  @override
  Future<bool> openAuthorize({required String state}) async {
    openCalls++;
    lastState = state;
    return true;
  }

  /// 模拟站点回跳。测试里直接调它，不必真有一个浏览器。
  void simulateRedirect(Uri uri) {
    if (!_redirects.isClosed) _redirects.add(uri.toString());
  }

  Future<void> dispose() => _redirects.close();
}

/// 生产环境里「这台设备走不了授权」的占位。
///
/// 契约未确认、Android 深链未落地之前，非 Mock 构建走它：
/// `supported` 为 false，登录页据此不显示站点入口。
class UnsupportedSiteAuthLauncher implements SiteAuthLauncher {
  const UnsupportedSiteAuthLauncher();

  @override
  bool get supported => false;

  @override
  Stream<String> get redirects => const Stream<String>.empty();

  @override
  Future<bool> openAuthorize({required String state}) async => false;
}
