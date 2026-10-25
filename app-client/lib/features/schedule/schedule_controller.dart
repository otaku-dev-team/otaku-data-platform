import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/schedule.dart';
import '../../data/repositories/schedule_repository.dart';

/// 星期筛选。**不能用 `int?` 表示**——「全部」和「待定」都是 null，
/// 两个选项会永远分不开（实测踩过：点「待定」显示的是全部）。
enum ScheduleWeekday {
  all('全部'),
  monday('周一'),
  tuesday('周二'),
  wednesday('周三'),
  thursday('周四'),
  friday('周五'),
  saturday('周六'),
  sunday('周日'),
  undecided('待定');

  const ScheduleWeekday(this.label);

  final String label;

  /// 对应后端的 weekday 值（1..7 或 null=待定）；全部为 null 但语义不同，
  /// 由 [ScheduleWeekday] 本身区分，不走这个字段。
  int? get backendValue => switch (this) {
    ScheduleWeekday.monday => 1,
    ScheduleWeekday.tuesday => 2,
    ScheduleWeekday.wednesday => 3,
    ScheduleWeekday.thursday => 4,
    ScheduleWeekday.friday => 5,
    ScheduleWeekday.saturday => 6,
    ScheduleWeekday.sunday => 7,
    ScheduleWeekday.undecided => null,
    ScheduleWeekday.all => null,
  };
}

/// 选中的星期。默认 [ScheduleWeekday.all]：多数人点进来是想逛一圈，
/// 不是只看某一天。
class ScheduleWeekdayController extends Notifier<ScheduleWeekday> {
  @override
  ScheduleWeekday build() => ScheduleWeekday.all;

  void select(ScheduleWeekday weekday) {
    if (state == weekday) return;
    state = weekday;
  }
}

final scheduleWeekdayProvider =
    NotifierProvider<ScheduleWeekdayController, ScheduleWeekday>(
      ScheduleWeekdayController.new,
    );

/// 选中的季度。null = 后端默认（最新）。
class ScheduleSeasonController extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? season) {
    if (state == season) return;
    state = season;
  }
}

final scheduleSeasonProvider =
    NotifierProvider<ScheduleSeasonController, String?>(
      ScheduleSeasonController.new,
    );

/// 档期数据。季度变化时重新拉取；星期只是本地过滤，不重新请求
/// （一个季度就几百条，一次拿全按天过滤比每天一次请求便宜）。
///
/// 关掉自动重试：页面已经有 `hasError` 分支和手动重试按钮，但 Riverpod 3 的
/// 默认重试会先退避 10 次（200ms→6400ms）才把错误透出来——那段时间用户看到的
/// 是"一直转圈"，而档期页拿不到数据本来就该立刻说"加载失败，点这里重试"。
final scheduleProvider = FutureProvider<SchedulePageData>(
  (ref) {
    final season = ref.watch(scheduleSeasonProvider);
    return ref.watch(scheduleRepositoryProvider).fetchSchedule(season: season);
  },
  retry: (retryCount, error) => null,
);

/// 当前筛选下的条目。换天只是重新过滤这份数据，不重新请求。
final visibleScheduleProvider = Provider<ScheduleGroup?>((ref) {
  final data = ref.watch(scheduleProvider).value;
  if (data == null) return null;
  final weekday = ref.watch(scheduleWeekdayProvider);

  if (weekday == ScheduleWeekday.all) {
    // 「全部」：合成一个组平铺展示，顺序即服务端分组顺序（周一…周日 + 待定）。
    return ScheduleGroup(
      weekday: null,
      label: '全部',
      items: [for (final group in data.groups) ...group.items],
    );
  }
  return data.groupOf(weekday.backendValue);
});
