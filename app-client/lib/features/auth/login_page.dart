import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_config.dart';
import '../../core/router/route_paths.dart';
import '../../core/theme/app_theme.dart';
import 'auth_controller.dart';

/// 登录页：**双入口**。
///
/// - 主入口「用 Otaku 账号登录」：App 内 WebView 承载站点授权页，注册与授权
///   同域，回来即登录。这是目标形态——平台账号只是过渡/兜底
///   （`product-positioning.md` §4）。形态取舍见 [`SiteAuthLauncher`] 的类注释。
/// - 次级入口「使用平台账号登录」：现有的用户名密码表单，收在次级按钮后面。
///
/// 为什么不是两个一样大的按钮：两个入口**不是对等关系**。让用户每次登录都先
/// 判断「我是哪种人」，是把产品的身份认知成本转嫁给用户。
///
/// 站点入口只在 `SiteAuthLauncher.supported` 为真时出现：Windows 桌面没有
/// WebView 实现、或构建期没注入 `SITE_BASE_URL` 时**隐藏**而不是置灰，
/// 不给点了没反应的按钮。
///
/// 表单校验故意很松（非空即可），真正的规则在服务端，客户端重复一遍只会
/// 出现「客户端说可以、服务端说不行」的分裂。
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final FocusNode _passwordFocus = FocusNode();

  /// 平台账号表单是否展开。默认收起：主路径是站点授权。
  bool _platformExpanded = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submitPlatform() async {
    final auth = ref.read(authControllerProvider);
    if (auth.submitting) return;

    final ok = await ref
        .read(authControllerProvider.notifier)
        .login(_username.text, _password.text);
    if (!mounted || !ok) return;

    _leave();
  }

  Future<void> _beginSiteLogin() async {
    await ref.read(authControllerProvider.notifier).beginSiteLogin();
    // 之后等回跳：成功由 SiteAuthBootstrap 处理，这里不跳转。
  }

  /// 登录成功后的落点：从收藏页跳来的就回去；直接打开登录页则去收藏页。
  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(RoutePaths.collections);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auth = ref.watch(authControllerProvider);
    final error = auth.error;
    final siteAuthSupported = ref.watch(siteAuthLauncherProvider).supported;

    return Scaffold(
      appBar: AppBar(title: const Text('登录')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.collections_bookmark_outlined,
                  size: 40,
                  color: AppTheme.brandInk(context),
                ),
                const SizedBox(height: 12),
                Text(
                  '登录后收藏会同步到手机和桌面',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                if (siteAuthSupported) ...[
                  _SiteLoginButton(
                    submitting: auth.submitting,
                    onPressed: _beginSiteLogin,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '会打开网站授权页，密码只在网站输入',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (!_platformExpanded)
                    TextButton(
                      onPressed: auth.submitting
                          ? null
                          : () => setState(() => _platformExpanded = true),
                      child: const Text('使用平台账号登录'),
                    )
                  else
                    _PlatformForm(
                      username: _username,
                      password: _password,
                      passwordFocus: _passwordFocus,
                      submitting: auth.submitting,
                      onSubmit: _submitPlatform,
                    ),
                ] else
                  // 桌面端：这一轮只有平台账号一条路（见类注释）。
                  _PlatformForm(
                    username: _username,
                    password: _password,
                    passwordFocus: _passwordFocus,
                    submitting: auth.submitting,
                    onSubmit: _submitPlatform,
                  ),
                // 失败必须显式呈现（C7）：不静默、不把界面留在「好像成功了」的状态。
                if (error != null) ...[
                  const SizedBox(height: 12),
                  _ErrorBanner(message: error.userMessage),
                ],
                const SizedBox(height: 12),
                TextButton(
                  onPressed: auth.submitting
                      ? null
                      : () => context.canPop()
                      ? context.pop()
                      : context.go(RoutePaths.contents),
                  child: const Text('先不登录'),
                ),
                if (kDebugMode) ...[
                  const SizedBox(height: 24),
                  Text(
                    // 这句话必须跟着数据源走：接上真接口之后还写着「任意密码都能登录」，
                    // 排查问题时会被自己误导。
                    AppConfig.useMock
                        ? '当前为 Mock 认证：任意非空账号密码可登录，密码填 wrong 可验证失败提示。'
                        : '当前连接真实接口：${AppConfig.baseUrl}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 站点授权主按钮。
class _SiteLoginButton extends StatelessWidget {
  const _SiteLoginButton({required this.submitting, required this.onPressed});

  final bool submitting;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: submitting ? null : onPressed,
      child: submitting
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Text('用 Otaku 账号登录'),
    );
  }
}

/// 平台账号表单（次级入口）。
class _PlatformForm extends StatelessWidget {
  const _PlatformForm({
    required this.username,
    required this.password,
    required this.passwordFocus,
    required this.submitting,
    required this.onSubmit,
  });

  final TextEditingController username;
  final TextEditingController password;
  final FocusNode passwordFocus;
  final bool submitting;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: username,
          autofocus: true,
          enabled: !submitting,
          textInputAction: TextInputAction.next,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: '账号',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => passwordFocus.requestFocus(),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: password,
          focusNode: passwordFocus,
          enabled: !submitting,
          obscureText: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: '密码',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => onSubmit(),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: submitting ? null : onSubmit,
          child: submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('登录'),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline,
            size: 18,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
