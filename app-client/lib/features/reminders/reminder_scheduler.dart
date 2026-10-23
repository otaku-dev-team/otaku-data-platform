import 'reminder_plan.dart';

/// 通知权限申请的结果。
///
/// 区分 `unsupported` 与 `denied` 是为了文案：「这台设备不支持」不该
/// 让用户去设置里翻权限开关。
enum ReminderPermission { granted, denied, unsupported }

/// 排程能力的抽象。
///
/// 界面与业务只认这一层：桌面端给 [NoopReminderScheduler]，测试给记录用的假实现。
/// 这样「什么时候提醒、提醒什么」的判断可以脱离平台单测，平台适配只剩
/// 「把这几条写进系统闹钟」这一件事。
abstract interface class ReminderScheduler {
  /// 用户点通知时的回调载荷流（当前是站内路由）。
  Stream<String> get taps;

  Future<ReminderPermission> requestPermission();

  /// 用 [slots] 整体替换已排的提醒。
  ///
  /// 是「替换」而不是「追加」：收藏或档期变化后重算，旧的那批必须消失，
  /// 否则取消追番之后仍会被提醒。
  Future<void> replaceAll(List<ReminderSlot> slots);

  Future<void> cancelAll();
}

/// 不做任何事的实现：桌面端、以及没开提醒时用它兜底。
class NoopReminderScheduler implements ReminderScheduler {
  const NoopReminderScheduler();

  @override
  Stream<String> get taps => const Stream<String>.empty();

  @override
  Future<ReminderPermission> requestPermission() async =>
      ReminderPermission.unsupported;

  @override
  Future<void> replaceAll(List<ReminderSlot> slots) async {}

  @override
  Future<void> cancelAll() async {}
}
