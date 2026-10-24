import '../models/schedule.dart';

/// 档期数据来源的抽象。真接口与 Mock 各实现一份。
abstract interface class ScheduleDataSource {
  /// [season] 省略时取后端默认（库内最新季度）。
  Future<SchedulePageData> fetchSchedule({String? season});
}
