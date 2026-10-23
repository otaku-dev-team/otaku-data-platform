import 'package:flutter/foundation.dart';

import '../../data/models/schedule.dart';

/// 一条待发的提醒：某一天，有几部在追的作品更新。
///
/// 一天一条，而不是一部一条。理由见 `docs/w1.3-notification-proposal.md` §3.1：
/// 档期里的 `broadcast_time` 是站点原文（`P 22:00`），**时区语义未定义**，
/// 按它算具体时刻等于替数据编一个假设；而用户真正要回答的问题是
/// 「今天有什么可看」，一条汇总就够了。
@immutable
class ReminderSlot {
  const ReminderSlot({
    required this.date,
    required this.firesAt,
    required this.entries,
  });

  /// 这一天（当地日期，时分秒归零）。用于去重与展示。
  final DateTime date;

  /// 实际发通知的时刻（当地时区，通常是当天 09:00）。
  final DateTime firesAt;

  /// 命中的档期条目。至少一条——空的那天不会生成 slot。
  final List<ScheduleEntry> entries;

  int get count => entries.length;

  /// 通知标题。
  String get title => '今天有 $count 部在追的番更新';

  /// 通知正文：最多列 3 部，多的用「等 N 部」收尾。
  ///
  /// 不在通知里塞整季清单：通知栏能显示的行数有限，截断位置由系统决定，
  /// 与其让它随缘截，不如自己控制成「3 个标题 + 总数」。
  String get body {
    final titles = [for (final entry in entries) entry.title];
    final head = titles.take(3).join('、');
    return count <= 3 ? head : '$head 等 $count 部';
  }

  /// 通知 id。用日期当 id：同一天重排会覆盖上一条，不会堆出两条一样的提醒；
  /// 也落在 32 位整数范围内（20261024）。
  int get notificationId => date.year * 10000 + date.month * 100 + date.day;

  @override
  String toString() => 'ReminderSlot($date, $count 部)';
}
