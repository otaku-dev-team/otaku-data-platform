import 'package:flutter/foundation.dart';

import 'work_summary.dart';

/// 同标签推荐的结果。契约：`GET /api/works/{work_id}/related`。
///
/// 边界（与服务端一致）：
/// - 作品没有标签 → `basis_tags: []` + `items: []`，**不是错误**，界面此时
///   整块不渲染，而不是显示"暂无推荐"。
/// - `items` 里的元素与列表接口的 [WorkSummary] 完全同构，可以直接复用卡片。
/// - 不返回作品自身。
@immutable
class RelatedWorks {
  const RelatedWorks({required this.basisTags, required this.items});

  /// 本次**实际参与匹配**的标签（最多 5 个）。界面据此展示「同题材：科幻、机战」
  /// 这类理由；为空表示作品没标签，此时 [items] 必然为空。
  final List<String> basisTags;

  final List<WorkSummary> items;

  bool get isEmpty => items.isEmpty;

  factory RelatedWorks.fromJson(Map<String, dynamic> json) {
    final rawTags = json['basis_tags'];
    final rawItems = json['items'];

    return RelatedWorks(
      basisTags: rawTags is List
          ? rawTags
                .whereType<String>()
                .map((tag) => tag.trim())
                .where((tag) => tag.isNotEmpty)
                .toList(growable: false)
          : const <String>[],
      items: rawItems is List
          ? [
              for (final item in rawItems)
                if (item is Map) WorkSummary.fromJson(Map<String, dynamic>.from(item)),
            ]
          : const <WorkSummary>[],
    );
  }
}
