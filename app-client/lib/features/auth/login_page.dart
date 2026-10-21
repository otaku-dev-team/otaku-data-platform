import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_config.dart';
import '../../core/router/route_paths.dart';
import 'auth_controller.dart';

/// 登录页。
///
/// 只做一件事：把用户名密码交给 [AuthController]，成功就返回来源页。
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

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final auth = ref.read(authControllerProvider);
    if (auth.submitting) return;

    final ok = await ref
        .read(authControllerProvider.notifier)
        .login(_username.text, _password.text);
    if (!mounted || !ok) return;

    // 从收藏页跳来的就回收藏页；直接打开登录页（深链接/冷启动）则去收藏页。
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
                  color: theme.colorScheme.primary,
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
                TextField(
                  controller: _username,
                  autofocus: true,
                  enabled: !auth.submitting,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '账号',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _passwordFocus.requestFocus(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  focusNode: _passwordFocus,
                  enabled: !auth.submitting,
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: '密码',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                // 失败必须显式呈现（C7）：不静默、不把界面留在「好像成功了」的状态。
                if (error != null) ...[
                  const SizedBox(height: 12),
                  _ErrorBanner(message: error.userMessage),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: auth.submitting ? null : _submit,
                  child: auth.submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('登录'),
                ),
                const SizedBox(height: 8),
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
