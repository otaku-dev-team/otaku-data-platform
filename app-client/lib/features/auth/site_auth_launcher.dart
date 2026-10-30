import 'dart:async';

/// 站点授权的「打开授权页」与「接回调」两端。
///
/// 为什么抽象出来：授权链路一半在页面里（站点自己的登录 / 注册页），一半在
/// App 内（scheme 回跳）。把这两端各自收成接口，业务层才能在不真开页面的
/// 情况下被完整测试——进程回收、state 过期这些都是单元测试该覆盖的，
/// 不该等到真机上九点钟才发现。
abstract interface class SiteAuthLauncher {
  /// 这台设备能不能走授权流程。
  ///
  /// 不能的原因有两个，都落在这里：平台没有 WebView 实现（Windows 桌面），
  /// 或构建期没注入 `SITE_BASE_URL`。界面据此**整块隐藏**入口，而不是置灰
  /// ——不给用户点了没反应的按钮。
  bool get supported;

  /// 回跳 URI 流。每个 URI 形如 `com.otaku.app:/oauth2redirect?ticket=…&state=…`。
  Stream<String> get redirects;

  /// 用户**没有完成授权就退出**了授权页（返回键 / 关闭按钮 / 路由被弹掉）。
  ///
  /// 必须单独有一条信号：[openAuthorize] 只负责「把页面推上去」，之后
  /// `submitting` 会一直挂着等回跳。用户中途放弃时不会再有回跳，没有这条
  /// 信号，登录按钮就会永远转圈（只能杀后台恢复）——真机复现过。
  Stream<void> get cancelled;

  /// 打开站点授权页。返回是否成功打开。
  ///
  /// ## 这里为什么不是「系统浏览器」
  ///
  /// 早先的实现要求「必须是系统浏览器，不能是 App 内 WebView」（RFC 8252：
  /// 用户要能从地址栏确认域名）。**Issue #238 起改成 App 内 WebView**，
  /// 理由是一个能压过它的产品事实：
  ///
  /// WebView 与系统浏览器是**两套 cookie 域**。`app-registration-approach.md` §3
  /// 承诺「注册完直接就是登录态」，靠的是注册建立的站点会话能被紧随其后的
  /// authorize 直接复用。跨到系统浏览器就复用了不了——用户得在浏览器里
  /// 再登录一次，那正是这个形态要消灭的一步。
  ///
  /// 所以：[WebViewSiteAuthLauncher] 主动放弃「外部用户代理」这条约束，
  /// 换取单次登录闭环。**代价必须明写**：
  /// - 用户无法从地址栏核对域名（App 内没有地址栏）；
  /// - 站点的登录页在 App 进程内渲染，App 技术上能读到用户输入。
  ///
  /// 后一条靠**实现纪律**守住而不是靠平台隔离：App 不注入取密码的脚本、
  /// 不读取 DOM，密码只在站点页面内提交。这也是为什么没有选「原生表单直 POST」
  /// （那是真的代收密码，撞红线，见 `app-registration-approach.md` §4）。
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
  final StreamController<void> _cancels = StreamController<void>.broadcast();

  int openCalls = 0;
  String? lastState;

  @override
  bool get supported => true;

  @override
  Stream<String> get redirects => _redirects.stream;

  @override
  Stream<void> get cancelled => _cancels.stream;

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

  /// 模拟用户退出授权页（未完成授权）。
  void simulateCancel() {
    if (!_cancels.isClosed) _cancels.add(null);
  }

  Future<void> dispose() async {
    await _redirects.close();
    await _cancels.close();
  }
}

/// 生产环境里「这台设备走不了授权」的占位。
///
/// 平台没有 WebView 实现（Windows 桌面）或没注入 `SITE_BASE_URL` 时用它：
/// `supported` 为 false，登录页据此不显示站点入口。
class UnsupportedSiteAuthLauncher implements SiteAuthLauncher {
  const UnsupportedSiteAuthLauncher();

  @override
  bool get supported => false;

  @override
  Stream<String> get redirects => const Stream<String>.empty();

  @override
  Stream<void> get cancelled => const Stream<void>.empty();

  @override
  Future<bool> openAuthorize({required String state}) async => false;
}
