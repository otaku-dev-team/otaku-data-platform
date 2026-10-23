import 'package:otaku_app/features/reminders/reminder_plan.dart';
import 'package:otaku_app/features/reminders/reminder_scheduler.dart';

/// 记录调用的排程替身。
///
/// 提醒真正的实现要系统通道（单测里调不了），所以「什么时候排、排了什么」
/// 这些判断都靠它来断言。
class FakeReminderScheduler implements ReminderScheduler {
  FakeReminderScheduler({this.permission = ReminderPermission.granted});

  ReminderPermission permission;

  /// 最后一次 `replaceAll` 收到的内容。`cancelAll` 之后清空。
  List<ReminderSlot> slots = const <ReminderSlot>[];

  int replaceCalls = 0;
  int cancelCalls = 0;
  int permissionCalls = 0;

  @override
  Stream<String> get taps => const Stream<String>.empty();

  @override
  Future<ReminderPermission> requestPermission() async {
    permissionCalls++;
    return permission;
  }

  @override
  Future<void> replaceAll(List<ReminderSlot> slots) async {
    replaceCalls++;
    this.slots = List<ReminderSlot>.of(slots);
  }

  @override
  Future<void> cancelAll() async {
    cancelCalls++;
    slots = const <ReminderSlot>[];
  }
}
