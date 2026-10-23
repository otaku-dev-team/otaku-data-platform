import '../../data/models/schedule.dart';
import 'reminder_plan.dart';

/// 把「在追的作品」和「档期」对成未来两周的提醒。
///
/// **纯函数，不碰时钟也不碰存储**：`now` 由调用方传进来。这样这段逻辑可以
/// 被完整单测——星期几算错、季度边界、空数据，都是在这一层暴露，
/// 而不是等到真机上九点钟没响才发现。
abstract final class ReminderPlanner {
  const ReminderPlanner._();

  /// 只排未来 14 天。
  ///
  /// 不做「每天重复」：档期按季度换，长期重复会在换季后继续报上一季的番。
  /// 14 天覆盖「两周没打开 App」的常见情况，超期就自然停——这比报错更安全，
  /// 也比假装一直在盯更诚实。
  static const int horizonDays = 14;

  /// 每天提醒的时刻（当地时区）。选早上：用户是在挑「今天看什么」，
  /// 而不是被剧情提醒打断。
  static const int sendHour = 9;
  static const int sendMinute = 0;

  /// [watchingWorkIds] 是「在看」状态的作品 id 集合；
  /// [schedule] 是当前季度的档期（`GET /api/schedule`）。
  ///
  /// 返回按日期升序的 slots。**没有命中的那一天不会出现在结果里**——
  /// 「今天没更新」是一件不需要通知的事。
  static List<ReminderSlot> plan({
    required Set<String> watchingWorkIds,
    required SchedulePageData schedule,
    required DateTime now,
    int horizonDays = horizonDays,
  }) {
    if (watchingWorkIds.isEmpty || horizonDays <= 0) {
      return const <ReminderSlot>[];
    }

    // 先按星期把命中的档期条目分好组，再按日期取——比「对每一天遍历全部条目」
    // 少绕一圈，也让顺序保持档期原有顺序（周一到周日、组内按服务端给的次序）。
    final byWeekday = <int, List<ScheduleEntry>>{};
    for (final group in schedule.groups) {
      for (final entry in group.items) {
        // 组上的 weekday 是分组依据，条目自己也带一份；优先条目自己的。
        final weekday = entry.weekday ?? group.weekday;
        final workId = entry.workId;
        // work_id 为空 = 这条档期还没对上本地作品，点了也进不去详情。
        // 提醒一个点不开的条目，比不提醒更糟。
        if (weekday == null || workId == null) continue;
        if (!watchingWorkIds.contains(workId)) continue;
        (byWeekday[weekday] ??= <ScheduleEntry>[]).add(entry);
      }
    }
    if (byWeekday.isEmpty) return const <ReminderSlot>[];

    final slots = <ReminderSlot>[];
    for (var offset = 0; offset < horizonDays; offset++) {
      // 用构造器加天数而不是 `add(Duration(days:))`：后者在夏令时切换日
      // 会把 00:00 变成 23:00 或 01:00，日期就错了一天。
      final date = DateTime(now.year, now.month, now.day + offset);
      // 今天如果已经过了提醒时刻，就不排了——排到过去的时间点，
      // 系统要么立刻弹一条，要么直接忽略，两种都不对。
      if (offset == 0 && !_stillAhead(now)) continue;

      final entries = byWeekday[date.weekday];
      if (entries == null || entries.isEmpty) continue;

      slots.add(
        ReminderSlot(
          date: date,
          firesAt: DateTime(
            date.year,
            date.month,
            date.day,
            sendHour,
            sendMinute,
          ),
          entries: _uniqueByWork(entries),
        ),
      );
    }
    return List<ReminderSlot>.unmodifiable(slots);
  }

  /// 同一部作品在档期里出现两次（跨来源、重复导入）时只留第一条。
  ///
  /// 不合并标题：条目本身是不同来源的记录，这里只是「别在同一条通知里
  /// 把同一部番数两遍」。
  static List<ScheduleEntry> _uniqueByWork(List<ScheduleEntry> entries) {
    final seen = <String>{};
    final unique = <ScheduleEntry>[];
    for (final entry in entries) {
      if (seen.add(entry.workId!)) unique.add(entry);
    }
    return List<ScheduleEntry>.unmodifiable(unique);
  }

  static bool _stillAhead(DateTime now) =>
      now.hour * 60 + now.minute < sendHour * 60 + sendMinute;
}
