import 'package:flutter/foundation.dart';

import 'source_rating.dart';
import 'work_type.dart';

/// 列表项。契约 2.1：**只有 6 个字段，没有 `summary`**。
/// 需要简介请按 `work_id` 拉详情，不要指望列表接口补。
@immutable
class WorkSummary {
  const WorkSummary({
    required this.workId,
    required this.workType,
    required this.title,
    this.coverUrl,
    this.tags,
    this.mainRating,
  });

  /// 不透明字符串：不得解析结构，不得做数值比较。
  final String workId;

  final WorkType workType;
  final String title;

  /// 平台代理地址；`null` 表示无封面，界面必须走占位图。
  final String? coverUrl;

  /// `null` 与 `[]` 在界面上同义：都不渲染标签区。
  final List<String>? tags;

  /// `null` 表示来源没有评分，界面不显示评分区。
  final SourceRating? mainRating;

  factory WorkSummary.fromJson(Map<String, dynamic> json) {
    final workId = json['work_id'];
    final title = json['title'];
    if (workId is! String || workId.isEmpty) {
      throw const FormatException('work_id 缺失或为空');
    }
    if (title is! String || title.isEmpty) {
      throw const FormatException('title 缺失或为空');
    }

    final coverUrl = json['cover_url'];
    return WorkSummary(
      workId: workId,
      workType: WorkType.fromValue(json['work_type']),
      title: title,
      coverUrl: coverUrl is String && coverUrl.isNotEmpty ? coverUrl : null,
      tags: parseTags(json['tags']),
      mainRating: SourceRating.tryParse(json['main_rating']),
    );
  }

  /// 空串、空数组、非数组一律归一为 `null`，界面少一层判断。
  static List<String>? parseTags(Object? raw) {
    if (raw is! List) return null;
    final tags = raw
        .whereType<String>()
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toList(growable: false);
    return tags.isEmpty ? null : tags;
  }

  @override
  String toString() => 'WorkSummary($workId, $title)';
}
