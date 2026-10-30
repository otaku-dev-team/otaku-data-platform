import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/telemetry/usage_ping.dart';

/// 每次启动打一次心跳（12 小时节流），只用于统计装机量与日活。
///
/// 挂在 `MaterialApp` 之外，与 `UpdateBootstrap` / `AppConfigBootstrap` 同一层：
/// 这是「跟启动走、不跟页面走」的事，用户落在哪一页、开没开登录都不影响。
///
/// 与它们的区别是**它永远不弹任何东西**：失败静默、不重试、不占首屏。
/// 这条约束写在这里而不是调用处，是因为后面很容易有人「顺手加个提示，
/// 至少让我们知道统计没发出去」——那会让每个弱网用户每次冷启动被骚扰。
class UsagePingBootstrap extends ConsumerStatefulWidget {
  const UsagePingBootstrap({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<UsagePingBootstrap> createState() => _UsagePingBootstrapState();
}

class _UsagePingBootstrapState extends ConsumerState<UsagePingBootstrap> {
  @override
  void initState() {
    super.initState();
    // 等第一帧画完：别和首页首屏抢带宽，也避免在 build 期间触发副作用。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 刻意不 await、不 catch：pingIfDue 内部已经吞掉所有异常。
      ref.read(usagePingProvider).pingIfDue();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
