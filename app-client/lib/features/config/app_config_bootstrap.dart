import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_config_controller.dart';

/// 启动时拉一次运行期配置（公告、开关、成人遮挡口径等）。
///
/// 放在 `MaterialApp` 之外的同一层，和 `UpdateBootstrap` / `SiteAuthBootstrap` 并列：
/// 配置跟"这次启动"走，不跟某个页面走——用户是深链进来的也要拿到。
///
/// **等第一帧画完再拉**：别和首页首屏抢带宽。失败不打扰用户（见数据源里的处理）。
class AppConfigBootstrap extends ConsumerStatefulWidget {
  const AppConfigBootstrap({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppConfigBootstrap> createState() => _AppConfigBootstrapState();
}

class _AppConfigBootstrapState extends ConsumerState<AppConfigBootstrap> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      // 不 await：配置不该拖慢启动，刷新完成后界面自己会重建
      ref.read(appConfigProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
