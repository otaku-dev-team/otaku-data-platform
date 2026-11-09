import 'package:flutter/foundation.dart';

import 'work_summary.dart';

/// 制作公司页（`GET /api/studios/{name}`，#557）。
///
/// `total` 是**该公司可见作品总数**，与 [items] 长度无关——一页最多 200 条，
/// 头部「本站收录 N 部」必须用它，不能用 `items.length`。
@immutable
class StudioPage {
  const StudioPage({
    required this.name,
    required this.total,
    required this.items,
  });

  /// 回显库里存的那个写法（NFKC 归一后精确匹配成功的名字），可直接当标题。
  final String name;

  final int total;

  final List<WorkSummary> items;

  factory StudioPage.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final items = <WorkSummary>[];
    if (rawItems is List) {
      for (final raw in rawItems) {
        if (raw is! Map) continue;
        try {
          items.add(WorkSummary.fromJson(Map<String, dynamic>.from(raw)));
        } on FormatException {
          // 单条坏卡不毁整页，与列表同一口径。
          continue;
        }
      }
    }
    return StudioPage(
      name: json['name'] is String ? json['name'] as String : '',
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
