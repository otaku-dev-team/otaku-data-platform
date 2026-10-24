import 'package:flutter/foundation.dart';

import 'source_rating.dart';
import 'work_type.dart';

/// 列表项。契约 2.1：**没有 `summary`**——简介要按 `work_id` 拉详情补。
///
/// 2026-10-24 起列表多返回一个 `source`（第 8 个字段）：跨源同名作品靠它区分。
@immutable
class WorkSummary {
  const WorkSummary({
    required this.workId,
    required this.workType,
    required this.title,
    this.releaseYear,
    this.coverUrl,
    this.tags,
    this.mainRating,
    this.source,
  });

  /// 不透明字符串：不得解析结构，不得做数值比较。
  final String workId;

  final WorkType workType;
  final String title;

  /// 来源年份。`null` 表示来源未提供，**不是 0 年**——界面此时不渲染年份。
  final int? releaseYear;

  /// 平台代理地址；`null` 表示无封面，界面必须走占位图。
  final String? coverUrl;

  /// `null` 与 `[]` 在界面上同义：都不渲染标签区。
  final List<String>? tags;

  /// `null` 表示来源没有评分，界面不显示评分区。
  final SourceRating? mainRating;

  /// 记录所属来源站的标识（`otaku_site` / `bangumi` …），**只用于让用户分得清
  /// 同名不同源的记录**，不参与任何归并判断。
  ///
  /// `null` 有两层意思：来源没标注，或**这份 JSON 是在字段上线之前缓存下来的**——
  /// 两种情况的处理一致（不渲染来源标识），所以老缓存解出来不会因为缺键而炸掉。
  final String? source;

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
      releaseYear: parseYear(json['release_year']),
      coverUrl: coverUrl is String && coverUrl.isNotEmpty ? coverUrl : null,
      tags: parseTags(json['tags']),
      mainRating: SourceRating.tryParse(json['main_rating']),
      source: parseSource(json['source']),
    );
  }

  /// 来源标识：非字符串或空串一律归一为 `null`，界面少一层判断。
  ///
  /// 老缓存里根本没有这个键，`json['source']` 直接就是 `null` —— 这里不许抛，
  /// 否则用户升级后打开列表会因为一份旧缓存整片崩掉（D3 上线时最容易踩的一处）。
  static String? parseSource(Object? raw) {
    if (raw is! String) return null;
    final value = raw.trim();
    return value.isEmpty ? null : value;
  }

  /// 非整数、超出 1900–2100 一律归一为 `null`。
  /// 契约保证后端不会发越界值，这里再挡一道是为了让界面逻辑永远只有一个分支。
  static int? parseYear(Object? raw) {
    final year = raw is int ? raw : (raw is num ? raw.toInt() : null);
    if (year == null || year < 1900 || year > 2100) return null;
    return year;
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

  /// 序列化。离线缓存用（见 `HiveWorkCache`）。
  ///
  /// 与 [fromJson] 对称。注意 `tags` 为空数组时写 `null`：
  /// 解析侧把空数组与 null 归一为同一个意思（都不渲染标签区），
  /// 这里保持一致，免得缓存往返一趟后语义变了。
  Map<String, dynamic> toJson() => {
    'work_id': workId,
    'work_type': workType.value,
    'title': title,
    'release_year': releaseYear,
    'cover_url': coverUrl,
    'tags': (tags == null || tags!.isEmpty) ? null : tags,
    'main_rating': mainRating?.toJson(),
    'source': source,
  };

  @override
  String toString() => 'WorkSummary($workId, $title)';
}
