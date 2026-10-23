import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/router/app_router.dart';
import '../../data/models/schedule.dart';
import '../auth/auth_controller.dart';
import '../schedule/schedule_controller.dart';
import 'reminder_service.dart';
import 'reminder_settings.dart';

/// 催促提醒重算、并接住「点通知」的那一下。
///
/// 放在 `MaterialApp` 外面一层，而不是塞进某个页面：提醒跟着账号与数据走，
/// 不跟着用户停在哪个页面走。用户可能整场都没打开过档期页。
class ReminderBootstrap extends ConsumerStatefulWidget {
  const ReminderBootstrap({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ReminderBootstrap> createState() => _ReminderBootstrapState();
}

class _ReminderBootstrapState extends ConsumerState<ReminderBootstrap> {
  StreamSubscription<String>? _taps;
  ProviderSubscription<AsyncValue<SchedulePageData>>? _scheduleSub;
  ProviderSubscription<AuthState>? _authSub;
  AppLifecycleListener? _lifecycle;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();

    _taps = ref.read(reminderSchedulerProvider).taps.listen(_openPayload);

    // 会话恢复是异步的：冷启动时先读到 checking，之后才变成 signedIn。
    // 不跟着它重排，第一次 refresh 会因为「还没有用户」而什么都不做，
    // 提醒就要等到下次切前台才排上。
    _authSub = ref.listenManual<AuthState>(authControllerProvider, (previous,
        next) {
      if (previous?.user?.userId == next.user?.userId &&
          previous?.status == next.status) {
        return;
      }
      _refreshSoon();
    });

    // 档期只在「提醒开着」时才订阅：否则每个用户每次冷启动都会白拉一次
    // 档期接口，而默认是关的。
    _syncScheduleSubscription(ref.read(reminderEnabledProvider));

    _lifecycle = AppLifecycleListener(onResume: _refreshSoon);

    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    _taps?.cancel();
    _scheduleSub?.close();
    _authSub?.close();
    _lifecycle?.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _syncScheduleSubscription(bool enabled) {
    if (enabled) {
      if (_scheduleSub != null) return;
      _scheduleSub = ref.listenManual<AsyncValue<SchedulePageData>>(
        scheduleProvider,
        (previous, next) {
          if (next.hasValue) _refreshSoon();
        },
      );
      // 订阅时数据可能已经在了（切开关回来），补一次，别等下一次变化。
      if (ref.read(scheduleProvider).hasValue) _refreshSoon();
      return;
    }
    _scheduleSub?.close();
    _scheduleSub = null;
  }

  /// 合并短时间内的多次触发：启动、切前台、档期落盘常常前后脚到。
  void _refreshSoon() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), _refresh);
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    await ref.read(reminderServiceProvider).refresh();
  }

  /// 点通知 → 进档期页。载荷是站内路由（见 `LocalReminderScheduler`）。
  void _openPayload(String payload) {
    if (!mounted || payload.isEmpty) return;
    ref.read(appRouterProvider).go(payload);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(reminderEnabledProvider, (previous, next) {
      _syncScheduleSubscription(next);
      // 打开时立刻排；关闭时 service 里会 cancelAll。
      _refresh();
    });
    return widget.child;
  }
}
