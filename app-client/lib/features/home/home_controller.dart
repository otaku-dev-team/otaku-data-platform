import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/article.dart';
import '../../data/models/schedule.dart';
import '../../data/models/work_sort.dart';
import '../../data/models/work_summary.dart';
import '../../data/repositories/article_repository.dart';
import '../../data/repositories/schedule_repository.dart';
import '../../data/repositories/work_repository.dart';

/// 首页各区块的取数条数。
///
/// 首页是"入口"不是"容器"：每块只放够判断要不要点进去的量，
/// 想看得多点「查看全部」。条数写在这里而不是散在页面里，
/// 是因为它们同时决定了骨架屏的高度。
abstract final class HomeLimits {
  /// 本日新番最多露几条。一屏横向能扫完 8–10 条。
  static const int todaySchedule = 10;

  /// 高分作品横排的卡片数。
  static const int topRated = 10;

  /// 最新资讯的条数。三张卡片刚好占满一屏下半部分。
  static const int latestArticles = 3;
}

/// 今天星期几（1=周一 … 7=周日），与后端 `weekday` 同一个取值域。
///
/// 抽成 provider 是为了让测试固定住「今天」：直接读 `DateTime.now()`
/// 的用例只在某一个星期几才成立，周二写完周四就红。
final homeTodayWeekdayProvider = Provider<int>((ref) => DateTime.now().weekday);

/// 本日新番。
///
/// **不复用档期页的 `scheduleProvider`**：那个 provider 跟着「选中的季度」走，
/// 用户在档期页翻到 2020 年某季之后回首页，首页会显示那一季的「今天」。
/// 首页的语义是「最新一季的今天」，所以自己按默认季度取一次。
/// 代价是多一次请求，换来的是两个页面各自说自己的话。
final homeTodayScheduleProvider = FutureProvider<ScheduleGroup?>(
  (ref) async {
    final data = await ref.watch(scheduleRepositoryProvider).fetchSchedule();
    return data.groupOf(ref.watch(homeTodayWeekdayProvider));
  },
  // 区块级失败由区块自己呈现（一条带重试的窄条），不需要后台重试——
  // 重试会让失败看起来像"一直在加载"。
  retry: (retryCount, error) => null,
);

/// 高分作品。
///
/// 复用列表接口的 `sort=rating`：服务端已按评分降序、无评分沉底，
/// 首页拿第一页就是"分最高的那几部"，不需要新接口。
///
/// ## 已知数据问题：满分墙（不是排序 bug）
///
/// 来源站（Bangumi）的 `score` 是平均值，但**没有「评分人数」维度**
/// （[`ranking-proposal.md`] §4 已定不做人数加权）。一条只有 1–2 人打 10 分的
/// 冷门短片会稳定压过 8.x 的长篇：2026-10-29 实测联调库 `sort=rating`
/// **前 10 页（500 条）全是 10.0**，第 20 页才降到 9.3。
///
/// 客户端筛不动这道墙（要翻十几页），所以这里不做「取多页再过滤」的假动作。
/// 根治有两条路，都需三人确认：
/// 1. 榜单加可选 `max_rating`（与 `min_rating` 对称），首页精选传 `≤9.9`；
/// 2. 数据侧从 Bangumi 档案的 `score_details` 算评分人数，低于阈值的评分
///    按「无评分」处理（需重导）。
final homeTopRatedProvider = FutureProvider<List<WorkSummary>>(
  (ref) async {
    final fetched = await ref.watch(workRepositoryProvider).fetchWorks(
      sort: WorkSort.rating,
      page: 1,
      pageSize: HomeLimits.topRated,
    );
    return fetched.value.items;
  },
  retry: (retryCount, error) => null,
);

/// 最新资讯。
final homeLatestArticlesProvider = FutureProvider<List<ArticleSummary>>(
  (ref) async {
    final page = await ref.watch(articleRepositoryProvider).fetchArticles(
      page: 1,
      pageSize: HomeLimits.latestArticles,
    );
    return page.items;
  },
  retry: (retryCount, error) => null,
);
