import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform_info.dart';
import '../../data/models/collection_entry.dart';
import '../../data/models/schedule.dart';
import '../../data/repositories/collection_repository.dart';
import '../../data/repositories/schedule_repository.dart';
import '../../data/repositories/work_repository.dart' show Fetched;
import '../auth/auth_controller.dart';
import 'local_reminder_scheduler.dart';
import 'reminder_planner.dart';
import 'reminder_scheduler.dart';
import 'reminder_settings.dart';

/// 排程实现。桌面端给空实现——Windows 本地通知要 AUMID/MSIX，属于 W6 的事。
final reminderSchedulerProvider = Provider<ReminderScheduler>((ref) {
  if (PlatformInfo.isDesktop) return const NoopReminderScheduler();
  return LocalReminderScheduler();
});

/// 把「在追的作品 × 档期」算成未来两周的提醒，整体替换系统里已排的那批。
///
/// 调用时机（见 `ReminderBootstrap` 与收藏控制器）：
/// App 启动 / 切回前台 / 档期加载完成 / 收藏变更 / 开关变化。
class ReminderService {
  ReminderService(this._ref, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final Ref _ref;

  /// 注入时钟是为了测「今天已过 9 点」这类分支——排程结果跟日期强相关，
  /// 让测试依赖真实当前时间等于让它掷骰子。
  final DateTime Function() _clock;

  /// 同一时刻只跑一份。启动与切前台可能挨得很近，重复跑没有害处但浪费请求。
  Future<void>? _inFlight;

  Future<void> refresh() {
    return _inFlight ??= _refresh().whenComplete(() => _inFlight = null);
  }

  Future<void> _refresh() async {
    final scheduler = _ref.read(reminderSchedulerProvider);

    if (!_ref.read(reminderEnabledProvider)) {
      // 关掉之后必须真的清空：用户关的是「别再提醒我」，不是「别再算」。
      await scheduler.cancelAll();
      return;
    }

    final userId = _ref.read(authControllerProvider).user?.userId;
    if (userId == null) {
      // 没登录就没有「在追」清单，留着上一个账号排的提醒是错的。
      await scheduler.cancelAll();
      return;
    }

    final SchedulePageData schedule;
    try {
      schedule = await _ref.read(scheduleRepositoryProvider).fetchSchedule();
    } on Object {
      // **拉不到就什么都不动**：把已排的清掉等于替数据回答「最近没有更新」，
      // 而实际上只是这次没拿到（铁律 3）。
      return;
    }

    final Fetched<List<CollectionEntry>> collections;
    try {
      collections = await _ref
          .read(collectionRepositoryProvider)
          .fetchAll(userId: userId, status: CollectionStatus.watching);
    } on Object {
      return;
    }

    final watching = <String>{
      for (final entry in collections.value)
        if (entry.status == CollectionStatus.watching) entry.workId,
    };

    final slots = ReminderPlanner.plan(
      watchingWorkIds: watching,
      schedule: schedule,
      now: _clock(),
    );

    // 档期拿到了但是在追清单为空 → slots 为空 → 清空已排的，这是对的：
    // 数据明确说「没有要提醒的」，不是「拿不到」。
    await scheduler.replaceAll(slots);
  }
}

final reminderServiceProvider = Provider<ReminderService>(ReminderService.new);
