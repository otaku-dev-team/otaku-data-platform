import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/router/app_router.dart';
import '../../core/router/route_paths.dart';
import 'auth_controller.dart';

/// 接住站点授权回跳的那一下。
///
/// 放在 `MaterialApp` 外面一层，而不是登录页里：**回跳时 App 不一定停在登录页**。
/// 用户点了登录 → 去系统浏览器 → 回来时进程可能已被回收，冷启动落在首页；
/// 订阅挂在登录页上，这个回跳就没人接，用户看到的是「点了没反应」。
class SiteAuthBootstrap extends ConsumerStatefulWidget {
  const SiteAuthBootstrap({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SiteAuthBootstrap> createState() => _SiteAuthBootstrapState();
}

class _SiteAuthBootstrapState extends ConsumerState<SiteAuthBootstrap> {
  StreamSubscription<String>? _redirects;

  @override
  void initState() {
    super.initState();
    _redirects = ref
        .read(siteAuthLauncherProvider)
        .redirects
        .listen(_onRedirect);
  }

  @override
  void dispose() {
    _redirects?.cancel();
    super.dispose();
  }

  Future<void> _onRedirect(String raw) async {
    final uri = Uri.tryParse(raw);
    if (uri == null) return;
    // scheme 可能被别的用途复用（以后加深链），只认授权回跳路径。
    if (uri.path != '/oauth2redirect' && uri.host != 'oauth2redirect') return;

    final ok = await ref
        .read(authControllerProvider.notifier)
        .handleSiteRedirect(uri);
    if (!ok || !mounted) return;

    // 落点与表单登录一致：从哪来回哪去，说不清就去收藏页。
    final router = ref.read(appRouterProvider);
    if (router.canPop()) {
      router.pop();
    } else {
      router.go(RoutePaths.collections);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
