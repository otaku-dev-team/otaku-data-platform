import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/tag_vocabulary.dart';
import '../models/work_summary.dart';
import '../models/work_type.dart';
import 'tag_data_source.dart';

/// Mock 词表：从本地目录里聚合，语义与服务端对齐。
///
/// - 只统计**有标签**的作品，`tags = null` 与 `[]` 都不产生词表行；
/// - 按 `count` 降序、同名按名称升序（与服务端同序，切换数据源时面板顺序不会跳）；
/// - `type` 过滤与列表页同一套取值。
class MockTagDataSource implements TagDataSource {
  MockTagDataSource({
    AssetBundle? bundle,
    this.latency = const Duration(milliseconds: 120),
  }) : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;
  final Duration latency;

  static const String _catalogAsset = 'assets/mock/works_catalog.json';

  List<WorkSummary>? _catalog;

  Future<List<WorkSummary>> _loadCatalog() async {
    final cached = _catalog;
    if (cached != null) return cached;

    final raw = await _bundle.loadString(_catalogAsset);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final items = <WorkSummary>[];
    final rawItems = json['items'];
    if (rawItems is List) {
      for (final item in rawItems) {
        if (item is! Map) continue;
        items.add(WorkSummary.fromJson(Map<String, dynamic>.from(item)));
      }
    }
    _catalog = items;
    return items;
  }

  @override
  Future<TagVocabulary> fetchTags({WorkType? type, int? limit}) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);

    final catalog = await _loadCatalog();
    final counts = <String, int>{};

    for (final work in catalog) {
      if (type != null && type != WorkType.unknown && work.workType != type) {
        continue;
      }
      final tags = work.tags;
      if (tags == null) continue;
      for (final raw in tags) {
        final name = raw.trim();
        if (name.isEmpty) continue;
        counts[name] = (counts[name] ?? 0) + 1;
      }
    }

    final items = counts.entries
        .map((entry) => TagCount(name: entry.key, count: entry.value))
        .toList()
      ..sort((a, b) {
        final byCount = b.count.compareTo(a.count);
        return byCount != 0 ? byCount : a.name.compareTo(b.name);
      });

    final capped = limit == null ? items : items.take(limit.clamp(1, 2000));
    return TagVocabulary(
      type: type?.value,
      total: capped.length,
      items: List.unmodifiable(capped),
    );
  }
}
