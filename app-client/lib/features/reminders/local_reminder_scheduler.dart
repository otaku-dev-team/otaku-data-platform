import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../core/router/route_paths.dart';
import 'reminder_plan.dart';
import 'reminder_scheduler.dart';

/// Android 上的本地提醒实现。
///
/// **只在 Android 上实例化**（见 `reminderSchedulerProvider`）：桌面端用
/// [NoopReminderScheduler]。Windows 的本地通知要 AUMID/MSIX 打包配合，
/// 牵动部署（W6 休眠中），这一轮不做——但也不假装有。
class LocalReminderScheduler implements ReminderScheduler {
  LocalReminderScheduler({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  final StreamController<String> _taps = StreamController<String>.broadcast();

  /// 初始化只做一次。插件在未初始化的状态下调用排程会抛，
  /// 而 `refresh()` 可能被启动、切前台、改收藏同时触发。
  Future<void>? _ready;

  static const AndroidNotificationDetails _details = AndroidNotificationDetails(
    'otaku_reminders',
    '追番提醒',
    channelDescription: '在追的作品更新当天提醒一次',
    importance: Importance.defaultImportance,
    priority: Priority.defaultPriority,
  );

  @override
  Stream<String> get taps => _taps.stream;

  Future<void> _ensureReady() {
    // 初始化失败不缓存这个失败：插件偶尔会因系统服务未就绪抛一次，
    // 把 rejected future 存下来，会让本次进程里所有后续尝试都直接失败，
    // 表现是「开关是开的，但再也不排了」，而且没有任何提示。
    return _ready ??= _initialize().catchError((
      Object error,
      StackTrace stack,
    ) {
      _ready = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<void> _initialize() async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload == null || payload.isEmpty) return;
        _taps.add(payload);
      },
    );
  }

  @override
  Future<ReminderPermission> requestPermission() async {
    await _ensureReady();
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final granted = await android?.requestNotificationsPermission();
    // null = 系统低于 Android 13，没有这个运行时权限项，视为已授予。
    return granted == false
        ? ReminderPermission.denied
        : ReminderPermission.granted;
  }

  @override
  Future<void> replaceAll(List<ReminderSlot> slots) async {
    await _ensureReady();
    // 先全清再排：收藏或档期变了之后，旧的那批必须消失。
    await _plugin.cancelAll();
    for (final slot in slots) {
      await _plugin.zonedSchedule(
        id: slot.notificationId,
        title: slot.title,
        body: slot.body,
        // 只用到「某个 UTC 瞬间」，所以不需要时区数据库：
        // 当地 09:00 经 `toUtc()` 得到确定的时刻，再交给系统。
        // 这样也避开了「拿不到 IANA 时区名就排不了」的问题。
        scheduledDate: tz.TZDateTime.from(slot.firesAt.toUtc(), tz.UTC),
        notificationDetails: const NotificationDetails(android: _details),
        // 不精确闹钟：不需要 SCHEDULE_EXACT_ALARM 权限，误差几分钟
        // 对「今天有什么更新」没有影响（方案 §3.1 的取舍）。
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        // 点通知去档期页：那里能看到全部当天更新，也是这条提醒的来源。
        payload: RoutePaths.schedule,
      );
    }
  }

  @override
  Future<void> cancelAll() async {
    await _ensureReady();
    await _plugin.cancelAll();
  }
}
