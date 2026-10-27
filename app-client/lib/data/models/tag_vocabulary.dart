import 'package:flutter/foundation.dart';

/// 标签词表里的一项：标签名 + 作品数。
///
/// `count` 是**作品数**，只统计当前快照；来源没提供标签的作品不计入任何标签
/// （契约 `GET /api/tags` 的约定）。
@immutable
class TagCount {
  const TagCount({required this.name, required this.count});

  final String name;
  final int count;

  factory TagCount.fromJson(Map<String, dynamic> json) {
    final rawName = json['name'];
    final rawCount = json['count'];
    return TagCount(
      name: rawName is String ? rawName : '',
      count: rawCount is num ? rawCount.toInt() : 0,
    );
  }

  @override
  String toString() => 'TagCount($name, $count)';
}

/// 标签词表。
///
/// `total` 是**本次返回的条数**，不是词表总数（与首站同语义）。
@immutable
class TagVocabulary {
  const TagVocabulary({
    this.type,
    required this.total,
    required this.items,
  });

  /// 服务端回显的类型过滤；省略时可能是 null。
  final String? type;
  final int total;
  final List<TagCount> items;

  static const TagVocabulary empty = TagVocabulary(total: 0, items: []);

  factory TagVocabulary.fromJson(Map<String, dynamic> json) {
    final rawType = json['type'];
    final rawTotal = json['total'];
    final rawItems = json['items'];

    final items = <TagCount>[];
    if (rawItems is List) {
      for (final raw in rawItems) {
        if (raw is! Map) continue;
        final item = TagCount.fromJson(Map<String, dynamic>.from(raw));
        // 空名字不该进面板：点了也筛不出东西。
        if (item.name.trim().isEmpty) continue;
        items.add(item);
      }
    }

    return TagVocabulary(
      type: rawType is String ? rawType : null,
      total: rawTotal is num ? rawTotal.toInt() : items.length,
      items: List.unmodifiable(items),
    );
  }

  @override
  String toString() => 'TagVocabulary(total: $total, items: ${items.length})';
}
