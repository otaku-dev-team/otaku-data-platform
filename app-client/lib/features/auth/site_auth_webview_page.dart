import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/config/app_config.dart';
import 'site_auth_urls.dart';

/// 交给 [SiteAuthWebViewPage] 的一次授权请求。
///
/// 为什么要带回调而不是让页面去 `ref.read(launcher)` 再强转：
/// 页面只需要知道自己「把回跳交给谁」，不需要认识 SiteAuthLauncher 这层抽象，
/// 这样用一个纯 Widget 参数就能在测试里替换掉真实的流。
@immutable
class SiteAuthWebViewArgs {
  const SiteAuthWebViewArgs({
    required this.state,
    required this.onRedirect,
    this.onCancelled,
  });

  final String state;

  /// 收到回跳时调用，参数是原始 URI 字符串（与 `SiteAuthLauncher.redirects` 同形）。
  final void Function(String uri) onRedirect;

  /// 用户**没有回跳就关掉页面**时调用（返回键退到根 / 关闭按钮 / 系统返回）。
  ///
  /// 不上报这一下，登录页的 `submitting` 会一直为 true，按钮永远转圈。
  final VoidCallback? onCancelled;
}

/// App 内 WebView 承载站点授权 / 注册页。
///
/// 形态见 `docs/app-registration-approach.md` §3：**注册与授权在同一个 WebView 里**，
/// 共享同一个 cookie 域。这样「注册完直接就是登录态」才成立——换成
/// 「WebView 注册 + 系统浏览器授权」两套 cookie 是打不通的。
///
/// 站点侧的实测行为（2026-10-28）：
/// `/oauth/authorize`（未登录）→ 303 到 `/login?next=<authorize 完整地址>`，
/// 登录页里带 `<a href="/register?next=…">`。所以**只加载 authorize 一条地址就够了**，
/// 用户在哪一步登录 / 注册都由站点自己决定，客户端不拼 `/register`。
class SiteAuthWebViewPage extends ConsumerStatefulWidget {
  const SiteAuthWebViewPage({super.key, required this.args});

  final SiteAuthWebViewArgs args;

  @override
  ConsumerState<SiteAuthWebViewPage> createState() =>
      _SiteAuthWebViewPageState();
}

class _SiteAuthWebViewPageState extends ConsumerState<SiteAuthWebViewPage> {
  late final WebViewController _controller;
  double _progress = 0;
  String? _error;
  bool _delivered = false;

  @override
  void dispose() {
    // 没走到回跳就离开了授权页 = 用户放弃这次登录。必须把「正在登录」清掉，
    // 否则登录页的按钮会一直转圈，只能杀后台恢复（真机复现）。
    //
    // 放到微任务里：dispose 可能发生在路由弹出的布局阶段，此时同步改
    // Riverpod 状态会触发正在构建的页面重建。
    if (!_delivered) {
      final onCancelled = widget.args.onCancelled;
      if (onCancelled != null) {
        Future<void>.microtask(onCancelled);
      }
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      // 站点登录 / 注册页依赖脚本（验证码、表单校验），关掉 JS 会是空白页。
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (value) {
            if (mounted) setState(() => _progress = value / 100);
          },
          onNavigationRequest: _onNavigationRequest,
          // 有些 WebView 实现不会把自定义 scheme 交给 onNavigationRequest
          // （尤其 3xx 跳转后），这里兜一道，保证回跳不会被漏掉。
          onUrlChange: (change) {
            final url = change.url;
            if (url != null) _maybeDeliver(url);
          },
          onWebResourceError: (error) {
            // 子资源（favicon 之类）失败不该把整页切成错误态；
            // `isForMainFrame` 在部分平台为 null，只在明确是子帧时跳过。
            if (!mounted || error.isForMainFrame == false) return;
            setState(() => _error = error.description);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _progress = 1);
          },
        ),
      );

    final base = AppConfig.siteBaseUrl;
    if (base.isEmpty) {
      // 还没 build 过，直接赋值即可（setState 在 initState 里没有意义）。
      _error = '未配置站点地址，无法在 App 内登录。';
      return;
    }
    _controller.loadRequest(
      SiteAuthUrls.authorize(siteBaseUrl: base, state: widget.args.state),
    );
  }

  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    if (SiteAuthUrls.isRedirect(Uri.parse(request.url))) {
      _maybeDeliver(request.url);
      return NavigationDecision.prevent;
    }
    return NavigationDecision.navigate;
  }

  /// 交付回跳**只做一次**：`onNavigationRequest` 与 `onUrlChange` 会先后触发，
  /// 不设闸门就会把一个一次性票据投递两遍——第二次必然失败，用户看到的是
  /// 「登录失败，请重试」，而其实第一次已经成功了。
  void _maybeDeliver(String raw) {
    if (_delivered) return;
    final uri = Uri.tryParse(raw);
    if (uri == null) return;
    if (!SiteAuthUrls.isRedirect(uri)) return;
    _delivered = true;
    widget.args.onRedirect(raw);
    // 立刻收起 WebView：票据已经交出去了，把已完成的授权页留在栈上
    // 只会让用户以为还得再点一次。后续跳转由 `SiteAuthBootstrap` 负责。
    if (mounted) _pop();
  }

  void _pop() {
    if (context.canPop()) {
      context.pop();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  /// 先还 WebView 历史，退到头才关页。
  ///
  /// 不用 `PopScope(canPop: false)` 接系统返回：那会把这里和 AppBar 的关闭按钮
  /// 一起挡住（`maybePop` 也会被拦），表现成「点了 X 关不掉」。
  Future<void> _handleBack() async {
    if (await _controller.canGoBack()) {
      await _controller.goBack();
      return;
    }
    if (mounted) _pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('登录 / 注册'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
          onPressed: _handleBack,
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: _progress < 1 && _error == null
              ? LinearProgressIndicator(value: _progress == 0 ? null : _progress)
              : const SizedBox(height: 2),
        ),
      ),
      body: _error == null
          ? WebViewWidget(controller: _controller)
          : _ErrorView(
              message: _error!,
              onRetry: () {
                setState(() {
                  _error = null;
                  _progress = 0;
                });
                _controller.reload();
              },
            ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Text(
          '密码只在网站页面里输入，App 不读取也不保存',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off_rounded,
                size: 40, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text('打不开站点页面', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
