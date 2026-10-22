import '../models/schedule.dart';
import 'schedule_data_source.dart';

/// Mock 档期数据。`USE_MOCK=true` 时使用，保证页面在无后端时也能看。
///
/// 形态与真实接口一致：按星期分组、空组保留、`work_id` 有命中与未命中
/// 两种样本（客户端要练的是「未命中不可跳转」这条分支）。
class MockScheduleDataSource implements ScheduleDataSource {
  const MockScheduleDataSource();

  static const SchedulePageData _page = SchedulePageData(
    season: '202610',
    seasons: ['202610', '202607'],
    groups: [
      ScheduleGroup(
        weekday: 1,
        label: '周一',
        items: [
          ScheduleEntry(
            scheduleId: 'S-mock001',
            title: '示例新番 A',
            seasonCode: '202610',
            weekday: 1,
            broadcastTime: '22:00',
            broadcastNote: '10/5周一深夜',
            workType: '小说改编动画',
            tags: ['奇幻', '冒险'],
            imageUrl: null,
            workId: 'W-mockwork01',
          ),
        ],
      ),
      ScheduleGroup(weekday: 2, label: '周二', items: []),
      ScheduleGroup(weekday: 3, label: '周三', items: []),
      ScheduleGroup(weekday: 4, label: '周四', items: []),
      ScheduleGroup(weekday: 5, label: '周五', items: []),
      ScheduleGroup(
        weekday: 6,
        label: '周六',
        items: [
          ScheduleEntry(
            scheduleId: 'S-mock002',
            title: '示例新番 B（未收录，不可跳转）',
            seasonCode: '202610',
            weekday: 6,
            broadcastNote: '周六 25:00',
            workType: '漫画改编动画',
            tags: ['日常'],
            workId: null,
          ),
        ],
      ),
      ScheduleGroup(weekday: 7, label: '周日', items: []),
      ScheduleGroup(weekday: null, label: '待定', items: []),
    ],
  );

  @override
  Future<SchedulePageData> fetchSchedule({String? season}) async {
    return _page;
  }
}
