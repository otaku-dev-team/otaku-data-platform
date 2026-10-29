import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/router/app_router.dart';
import 'update_controller.dart';
import 'update_dialog.dart';

/// 每次启动检查一次更新。
///
/// 挂在 `MaterialApp` 之外（与 `SiteAuthBootstrap` 同一层），所以弹窗要靠
/// 根 Navigator 的 key 拿 context——这样即使用户是深链进来的，也能弹出来。
///
/// **Mock 模式（含全部 widget 测试）不检查**：清单地址是构建期注入的，
/// Mock 包下它指向不存在的服务，发请求只会拖慢启动，还会给测试留一个
/// 真实网络请求。
class UpdateBootstrap extends ConsumerStatefulWidget {
  const UpdateBootstrap({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<UpdateBootstrap> createState() => _UpdateBootstrapState();
}

class _UpdateBootstrapState extends ConsumerState<UpdateBootstrap> {
  @override
  void initState() {
    super.initState();
    // 等第一帧画完再检查：别和首页的首屏渲染抢带宽，也保证 Navigator 已挂载。
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    if (AppConfig.useMock) return;

    final manifest = await ref
        .read(updateControllerProvider.notifier)
        .check();
    if (manifest == null || !mounted) return;

    final context = ref.read(appNavigatorKeyProvider).currentContext;
    if (context == null || !context.mounted) return;
    await showUpdateDialog(context, ref, manifest);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
