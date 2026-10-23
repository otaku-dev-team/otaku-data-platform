import 'package:flutter/foundation.dart';

import 'source_rating.dart';
import 'work_summary.dart';
import 'work_type.dart';

/// 详情。契约 2.1：全部 11 个字段。
@immutable
class Work {
  const Work({
    required this.workId,
    required this.workType,
    required this.title,
    this.summary,
    this.releaseYear,
    this.coverUrl,
    this.tags,
    this.mainRating,
    this.source = '',
    this.sourceId = '',
    this.sourceUrl,
    this.updatedAt,
  });

  final String workId;
  final WorkType workType;
  final String title;

  /// 最长 7225 字，`\n` 为段落分隔；`null` 表示来源没有简介。
  final String? summary;

  /// 来源年份。`null` 表示来源未提供，不是 0 年。
  final int? releaseYear;

  final String? coverUrl;
  final List<String>? tags;
  final SourceRating? mainRating;

  /// 溯源信息。`source` 固定 `otaku_site`；`sourceId` 只用于展示，
  /// **不得拿它做业务判断**（跨站点可能重复）。
  final String source;
  final String sourceId;

  /// 来源站**人读页**地址（契约 §2.1）。`null` 表示来源未提供或格式不可信，
  /// 此时详情页不显示「在来源站查看」入口。
  ///
  /// 只用于导航：不据此拉取任何数据，也不自行拼接。
  final String? sourceUrl;

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
      summary: summary is String && summary.trim().isNotEmpty ? summary : null,
      releaseYear: WorkSummary.parseYear(json['release_year']),
      coverUrl: coverUrl is String && coverUrl.isNotEmpty ? coverUrl : null,
      tags: WorkSummary.parseTags(json['tags']),
      mainRating: SourceRating.tryParse(json['main_rating']),
      source: source is String ? source : '',
      sourceId: sourceId is String ? sourceId : '',
      sourceUrl: parseSourceUrl(json['source_url']),
      updatedAt: updatedAt is String ? DateTime.tryParse(updatedAt) : null,
    );
  }

  /// 只接受 `http` / `https` 且 host 非空的地址。
  ///
  /// 服务端已经过滤过协议（契约 §2.1），客户端再做一层不是不信任上游，而是
  /// 这个值最终会交给**系统浏览器**打开：`javascript:`、`file:`、`intent:`
  /// 这类协议一旦漏过来，风险不在我们的进程里，而在系统层面。多校验一次的成本
  /// 只是一个 Uri.tryParse。
  static String? parseSourceUrl(Object? raw) {
    if (raw is! String) return null;
    final text = raw.trim();
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    if (uri.host.isEmpty) return null;
    return uri.toString();
  }

  /// 序列化。离线缓存用（见 `HiveWorkCache`）。
  ///
  /// 与 [fromJson] 对称。[sourceUrl] 走 [parseSourceUrl] 归一：
  /// 缓存里存一个不合规的地址没有意义，解析侧也会把它挡掉。
  Map<String, dynamic> toJson() => {
    'work_id': workId,
    'work_type': workType.value,
    'title': title,
    'summary': summary,
    'release_year': releaseYear,
    'cover_url': coverUrl,
    'tags': (tags == null || tags!.isEmpty) ? null : tags,
    'main_rating': mainRating?.toJson(),
    'source': source,
    'source_id': sourceId,
    'source_url': sourceUrl,
    'updated_at': updatedAt?.toUtc().toIso8601String(),
  };

  @override
  String toString() => 'Work($workId, $title)';
}
