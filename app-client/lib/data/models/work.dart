import 'package:flutter/foundation.dart';

import 'source_rating.dart';
import 'work_summary.dart';
import 'work_type.dart';

/// 详情。契约 2.1：全部 10 个字段。
@immutable
class Work {
  const Work({
    required this.workId,
    required this.workType,
    required this.title,
    this.summary,
    this.coverUrl,
    this.tags,
    this.mainRating,
    this.source = '',
    this.sourceId = '',
    this.updatedAt,
  });

  final String workId;
  final WorkType workType;
  final String title;

  /// 最长 7225 字，`\n` 为段落分隔；`null` 表示来源没有简介。
  final String? summary;

  final String? coverUrl;
  final List<String>? tags;
  final SourceRating? mainRating;

  /// 溯源信息。`source` 固定 `otaku_site`；`sourceId` 只用于展示，
  /// **不得拿它做业务判断**（跨站点可能重复）。
  final String source;
  final String sourceId;

  final DateTime? updatedAt;

  factory Work.fromJson(Map<String, dynamic> json) {
    final workId = json['work_id'];
    final title = json['title'];
    if (workId is! String || workId.isEmpty) {
      throw const FormatException('work_id 缺失或为空');
    }
    if (title is! String || title.isEmpty) {
      throw const FormatException('title 缺失或为空');
    }

    final summary = json['summary'];
    final coverUrl = json['cover_url'];
    final source = json['source'];
    final sourceId = json['source_id'];
    final updatedAt = json['updated_at'];

    return Work(
      workId: workId,
      workType: WorkType.fromValue(json['work_type']),
      title: title,
      summary: summary is String && summary.trim().isNotEmpty
          ? summary
          : null,
      coverUrl: coverUrl is String && coverUrl.isNotEmpty ? coverUrl : null,
      tags: WorkSummary.parseTags(json['tags']),
      mainRating: SourceRating.tryParse(json['main_rating']),
      source: source is String ? source : '',
      sourceId: sourceId is String ? sourceId : '',
      updatedAt: updatedAt is String ? DateTime.tryParse(updatedAt) : null,
    );
  }

  @override
  String toString() => 'Work($workId, $title)';
}
