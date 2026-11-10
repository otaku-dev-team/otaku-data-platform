import 'package:flutter/foundation.dart';

import 'work_summary.dart';

/// 系列页（`GET /api/series/{key}`，#557 / #558）。
///
/// 与详情页的 [WorkSeries] 是两个入口：这里是**目录页**（按评分排、分页、带总数），
/// 那里是「当前作品在系列里的位置」（按年代排、带关系标签）。
@immutable
class SeriesPage {
  const SeriesPage({
    required this.key,
    this.name,
    required this.total,
    required this.items,
  });

  /// 系列键，来源站内部 id。**不透明字符串，客户端不得解析**。
  final String key;

  /// `null` = 作品先导入、系列行还没到（两张表分开导入，是常态）。
  /// 此时页面退化成「系列」二字，**不能拿 [key] 顶替**——那是内部 id。
  final String? name;

  /// 可见作品总数（成人 / 已下架 / 未收录剔除后），与 [items] 长度无关。
  /// 首站把截断后的 `len(contents)` 当总数，超过 60 部的系列数字就是错的。
  final int total;

  final List<WorkSummary> items;

  factory SeriesPage.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final items = <WorkSummary>[];
    if (rawItems is List) {
      for (final raw in rawItems) {
        if (raw is! Map) continue;
        try {
          items.add(WorkSummary.fromJson(Map<String, dynamic>.from(raw)));
        } on FormatException {
          // 单条坏卡不毁整页，与列表 / 公司页同一口径。
          continue;
        }
      }
    }
    final key = json['key'];
    final name = json['name'];
    return SeriesPage(
      key: key is String ? key : '',
      name: name is String && name.trim().isNotEmpty ? name : null,
      total: switch (json['total']) {
        final int value => value,
        final num value => value.toInt(),
        final String value => int.tryParse(value) ?? items.length,
        _ => items.length,
      },
      items: List<WorkSummary>.unmodifiable(items),
    );
  }
}
