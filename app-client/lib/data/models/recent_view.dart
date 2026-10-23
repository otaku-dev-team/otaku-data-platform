import 'package:flutter/foundation.dart';

import 'work.dart';
import 'work_summary.dart';

/// 一条「最近浏览」记录：打开详情时看到的那份快照 + 打开时间。
///
/// 为什么存**快照**而不只存 `work_id`：首页那条横排要立刻画出卡片，
/// 而契约里没有「按 id 批量取作品」的接口。只存 id 的话，渲染一次横排要发
/// 五十个详情请求；断网时更是一条都画不出来——而「最近浏览」恰恰是断网时
/// 最该有内容的地方（呼应铁律 3：不把"抓不到"呈现成"没有"）。
///
/// 快照会过期（评分、封面可能后来变了），但点进去的详情页永远走实时接口，
/// 这一层只负责让用户认出"这是哪一部"。
@immutable
class RecentView {
  const RecentView({required this.work, required this.viewedAt});

  /// 打开详情那一刻的列表项快照。
  final WorkSummary work;

  /// 打开时间（本地时区）。
  final DateTime viewedAt;

  String get workId => work.workId;

  /// 从详情模型取快照。
  ///
  /// 只取 [WorkSummary] 有的七个字段：简介、来源站地址这些卡片用不上，
  /// 存进去只会让每条历史从两百字节涨到几 KB，而历史上限是 50 条。
  factory RecentView.of(Work work, {DateTime? viewedAt}) {
    return RecentView(
      work: WorkSummary(
        workId: work.workId,
        workType: work.workType,
        title: work.title,
        releaseYear: work.releaseYear,
        coverUrl: work.coverUrl,
        tags: work.tags,
        mainRating: work.mainRating,
      ),
      viewedAt: viewedAt ?? DateTime.now(),
    );
  }

  /// 序列化。存盘用（见 `RecentViewsCodec`）。
  Map<String, dynamic> toJson() => {
    'work': work.toJson(),
    'viewed_at': viewedAt.toUtc().toIso8601String(),
  };

  /// 解析。**只接受认得出的记录**：作品字段或时间坏了就抛 [FormatException]，
  /// 由编解码层跳过这一条——一条脏数据不该让整段历史作废。
  factory RecentView.fromJson(Map<String, dynamic> json) {
    final work = json['work'];
    final viewedAt = json['viewed_at'];
    if (work is! Map) throw const FormatException('最近浏览记录缺少 work');
    if (viewedAt is! String) throw const FormatException('最近浏览记录缺少 viewed_at');

    final at = DateTime.tryParse(viewedAt);
    if (at == null) throw const FormatException('viewed_at 不是合法时间');

    return RecentView(
      // 内层可能因 work_id / title 缺失再抛一次，两处都是 FormatException，
      // 调用方统一按「跳过这一条」处理。
      work: WorkSummary.fromJson(Map<String, dynamic>.from(work)),
      // 存的是 UTC，读回来转本地：比较与展示都按用户所在时区走。
      viewedAt: at.toLocal(),
    );
  }

  @override
  String toString() => 'RecentView($workId, $viewedAt)';
}
