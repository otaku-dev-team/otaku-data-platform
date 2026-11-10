import 'package:flutter/foundation.dart';

import 'work_summary.dart';

/// 系列清单里这一张卡**在本作视角下**的身份（#557）。
///
/// 中文文案由客户端映射，不要按标题猜。目前线上只会给 `sameSeries`：
/// 前作 / 续作 / 衍生作的关系数据还没落库（数据集有 `work_relations` 表，
/// publisher 不写），这不是占位假值——它们确实同系列。未知值一律回落到
/// `sameSeries`，这样后端将来加档位时老客户端不会整块解析失败。
enum SeriesRelation {
  prequel('prequel', '前作'),
  sequel('sequel', '续作'),
  spinOff('spin_off', '衍生作'),
  sameSeries('same_series', '同系列');

  const SeriesRelation(this.wire, this.label);

  final String wire;

  final String label;

  static SeriesRelation fromWire(Object? raw) {
    for (final value in SeriesRelation.values) {
      if (value.wire == raw) return value;
    }
    return SeriesRelation.sameSeries;
  }
}

/// `GET /api/works/{work_id}/series` 里的一项：`{relation, work}`。
///
/// 2026-11-09（#557）起不再返回裸 WorkSummary —— 关系标签不属于作品卡本身，
/// 所以外面多包了一层。解析时少解一层会把整页系列区画成空的。
@immutable
class WorkSeriesItem {
  const WorkSeriesItem({required this.relation, required this.work});

  final SeriesRelation relation;

  final WorkSummary work;

  factory WorkSeriesItem.fromJson(Map<String, dynamic> json) {
    final rawWork = json['work'];
    if (rawWork is! Map) {
      throw const FormatException('series item 缺 work');
    }
    return WorkSeriesItem(
      relation: SeriesRelation.fromWire(json['relation']),
      work: WorkSummary.fromJson(Map<String, dynamic>.from(rawWork)),
    );
  }
}

/// 详情页「系列作品」区（`GET /api/works/{work_id}/series`，#411 / #557）。
///
/// **没有系列不是错误**：`series_key` / `series_name` 为 null、`items` 为空，
/// HTTP 仍是 200。`items` 包含当前作品（系列是完整清单），由界面自己标记。
@immutable
class WorkSeries {
  const WorkSeries({
    this.seriesKey,
    this.seriesName,
    required this.items,
  });

  /// 不透明字符串，只用于拼系列页路径，**不解析、不展示**。
  final String? seriesKey;

  /// `null` = 系列行还没到。此时隐藏系列名，不要拿 [seriesKey] 顶替。
  final String? seriesName;

  final List<WorkSeriesItem> items;

  bool get isEmpty => items.isEmpty;

  factory WorkSeries.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final items = <WorkSeriesItem>[];
    if (rawItems is List) {
      for (final raw in rawItems) {
        if (raw is! Map) continue;
        try {
          items.add(WorkSeriesItem.fromJson(Map<String, dynamic>.from(raw)));
        } on FormatException {
          // 单条坏卡跳过，别让一个残缺条目把整个系列区吞掉。
          continue;
        }
      }
    }
    final key = json['series_key'];
    final name = json['series_name'];
    return WorkSeries(
      seriesKey: key is String && key.isNotEmpty ? key : null,
      seriesName: name is String && name.trim().isNotEmpty ? name : null,
      items: List<WorkSeriesItem>.unmodifiable(items),
    );
  }
}
