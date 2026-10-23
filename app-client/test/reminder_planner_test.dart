import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/data/models/schedule.dart';
import 'package:otaku_app/features/reminders/reminder_planner.dart';

/// 2026-10-24 是周六（weekday = 6）。
const int _saturday = 6;

ScheduleEntry _entry(
  String id, {
  String? workId,
  int? weekday,
  String? title,
}) => ScheduleEntry(
  scheduleId: 'S-$id',
  title: title ?? '番 $id',
  workId: workId,
  weekday: weekday,
  broadcastTime: '22:00',
);

ScheduleGroup _group(int? weekday, List<ScheduleEntry> items) =>
    ScheduleGroup(weekday: weekday, label: '$weekday', items: items);

SchedulePageData _page(List<ScheduleGroup> groups) => SchedulePageData(
  season: '202604',
  seasons: const ['202604'],
  groups: groups,
);

void main() {
  group('ReminderPlanner', () {
    test('只把「在看」里、并且 work_id 对得上的条目排进去', () {
      final slots = ReminderPlanner.plan(
        watchingWorkIds: const {'W-1'},
        schedule: _page([
          _group(_saturday, [
            _entry('a', workId: 'W-1'),
            _entry('b', workId: 'W-2'), // 不在「在看」里
            _entry('c'), // work_id 为空：点了进不去详情
          ]),
        ]),
        now: DateTime(2026, 10, 24, 8),
      );

      expect(slots, isNotEmpty);
      expect(slots.first.count, 1);
      expect(slots.first.entries.single.scheduleId, 'S-a');
    });

    test('今天还没到 9 点 → 今天也排；已过 9 点 → 从明天起', () {
      final schedule = _page([
        _group(_saturday, [_entry('a', workId: 'W-1')]),
      ]);

      final before = ReminderPlanner.plan(
        watchingWorkIds: const {'W-1'},
        schedule: schedule,
        now: DateTime(2026, 10, 24, 8, 59),
      );
      final after = ReminderPlanner.plan(
        watchingWorkIds: const {'W-1'},
        schedule: schedule,
        now: DateTime(2026, 10, 24, 9, 1),
      );

      expect(before.first.date, DateTime(2026, 10, 24));
      expect(after.first.date, DateTime(2026, 10, 31));
    });

    test('只排未来 14 天：offset 13 在内，offset 14 不在', () {
      // 2026-10-24 起：+7 = 10-31，+14 = 11-07
      final slots = ReminderPlanner.plan(
        watchingWorkIds: const {'W-1'},
        schedule: _page([
          _group(_saturday, [_entry('a', workId: 'W-1')]),
        ]),
        now: DateTime(2026, 10, 24, 8),
      );

      expect(slots.map((slot) => slot.date), [
        DateTime(2026, 10, 24),
        DateTime(2026, 10, 31),
      ]);
      expect(slots.map((slot) => slot.date.weekday).toSet(), {
        _saturday,
      }, reason: '星期映射错了会整天错位');
    });

    test('待定（weekday 为空）不排：它没有确定的日期', () {
      final slots = ReminderPlanner.plan(
        watchingWorkIds: const {'W-1'},
        schedule: _page([
          _group(null, [_entry('a', workId: 'W-1', weekday: null)]),
        ]),
        now: DateTime(2026, 10, 24, 8),
      );

      expect(slots, isEmpty);
    });

    test('没有命中任何一天 → 空结果，不生成空提醒', () {
      final slots = ReminderPlanner.plan(
        watchingWorkIds: const {'W-404'},
        schedule: _page([
          _group(_saturday, [_entry('a', workId: 'W-1')]),
        ]),
        now: DateTime(2026, 10, 24, 8),
      );

      expect(slots, isEmpty);
    });

    test('档期为空 / 在看为空 → 空结果', () {
      expect(
        ReminderPlanner.plan(
          watchingWorkIds: const {'W-1'},
          schedule: _page(const []),
          now: DateTime(2026, 10, 24, 8),
        ),
        isEmpty,
      );
      expect(
        ReminderPlanner.plan(
          watchingWorkIds: const {},
          schedule: _page([
            _group(_saturday, [_entry('a', workId: 'W-1')]),
          ]),
          now: DateTime(2026, 10, 24, 8),
        ),
        isEmpty,
      );
    });

    test('同一部作品在档期里出现两次，同一天只算一次', () {
      final slots = ReminderPlanner.plan(
        watchingWorkIds: const {'W-1'},
        schedule: _page([
          _group(_saturday, [
            _entry('a', workId: 'W-1'),
            _entry('b', workId: 'W-1'), // 跨来源重复
          ]),
        ]),
        now: DateTime(2026, 10, 24, 8),
      );

      expect(slots.first.count, 1);
    });

    test('通知文案：3 部以内直接列，超过 3 部用「等 N 部」收尾', () {
      final schedule = _page([
        _group(_saturday, [
          for (final id in ['W-1', 'W-2', 'W-3', 'W-4'])
            _entry(id, workId: id, title: '番$id'),
        ]),
      ]);
      final slots = ReminderPlanner.plan(
        watchingWorkIds: const {'W-1', 'W-2', 'W-3', 'W-4'},
        schedule: schedule,
        now: DateTime(2026, 10, 24, 8),
      );

      expect(slots.first.title, '今天有 4 部在追的番更新');
      expect(slots.first.body, '番W-1、番W-2、番W-3 等 4 部');
    });
  });
}
