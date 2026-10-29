import 'package:flutter/foundation.dart';

import 'source_rating.dart';
import 'work_character.dart';
import 'work_staff.dart';
import 'work_summary.dart';
import 'work_type.dart';

/// 详情。契约 2.1：**全部 20 个字段**（2026-10-28 扩入 4 个富字段与 3 个关联数组）。
@immutable
class Work {
  const Work({
    required this.workId,
    required this.workType,
    required this.title,
    this.titleOriginal,
    this.aliases,
    this.media,
    this.episodes,
    this.summary,
    this.releaseYear,
    this.coverUrl,
    this.tags,
    this.mainRating,
    this.staff,
    this.characters,
    this.studios,
    this.source = '',
    this.sourceId = '',
    this.sourceUrl,
    this.updatedAt,
  });

  final String workId;
  final WorkType workType;
  final String title;

  /// 原名（来源语言的原文标题）。`null` = 来源没有原名，**不要用 [title] 回填**——
  /// 两者相同时来源本就会给同一个值，回填只会让「有没有原名」这件事失去信号。
  final String? titleOriginal;

  /// 别名 / 译名列表。三态同 [tags]：`null` = 来源未提供，`[]` = 明确没有别名。
  ///
  /// 2026-10-29 起库里的空壳 `{\n}` 已洗成 `[]`（Issue #273），可以按数组直接渲染，
  /// 不用再防「一整段带花括号的文本」。
  final List<String>? aliases;

  /// 媒介形态（来源原值，中英混杂，不做归一）：`TV` / `剧场版` / `OVA` / `Web` …
  /// 不认识的值按原样显示，不得丢弃。
  final String? media;

  /// 话数 / 集数。`null` = 来源未提供（**不是 0 话**）。
  final int? episodes;

  /// 制作人员。三态：`null` / `[]` 都表示没有，界面都不渲染该区块。
  ///
  /// 一部最多 288 条（平均 20.5），**界面必须折叠**。
  /// 覆盖只有三到四成是数据事实，不是缺陷——不要据此画「完整度」指标。
  final List<WorkStaff>? staff;

  /// 角色与声优。三态与折叠要求同 [staff]，一部最多 60 条。
  final List<WorkCharacter>? characters;

  /// 制作公司名列表（来源原值，不做归一、不做别名合并）。一部最多 3 个。
  final List<String>? studios;

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
      titleOriginal: parseText(json['title_original']),
      aliases: parseStringList(json['aliases']),
      media: parseText(json['media']),
      episodes: parseEpisodes(json['episodes']),
      summary: summary is String && summary.trim().isNotEmpty ? summary : null,
      releaseYear: WorkSummary.parseYear(json['release_year']),
      coverUrl: coverUrl is String && coverUrl.isNotEmpty ? coverUrl : null,
      tags: WorkSummary.parseTags(json['tags']),
      mainRating: SourceRating.tryParse(json['main_rating']),
      staff: parseStaff(json['staff']),
      characters: parseCharacters(json['characters']),
      studios: parseStringList(json['studios']),
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

  /// 短文本：非字符串、空串、纯空白一律归一为 `null`。
  ///
  /// 与 [summary] 分开是因为富字段里「有没有值」本身就是信息（如原名），
  /// 空串不能当成「有值但为空」来渲染。
  static String? parseText(Object? raw) {
    if (raw is! String) return null;
    final text = raw.trim();
    return text.isEmpty ? null : raw;
  }

  /// 字符串数组，**保留三态**：非数组 → `null`；空数组 → `[]`。
  ///
  /// 契约对 `aliases` / `staff` / `characters` / `studios` 都定义了三态语义，
  /// 解析侧不把 `[]` 并进 `null`——界面上两者可以同样处理（都不渲染），
  /// 但缓存回写时要原样存回去，否则一次离线往返就把「明确没有」抹成了「未提供」。
  static List<String>? parseStringList(Object? raw) {
    if (raw is! List) return null;
    return raw
        .whereType<String>()
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  /// 话数：必须是 1–10000 的整数。`null` 表示来源未提供，**不是 0 话**。
  static int? parseEpisodes(Object? raw) {
    final value = raw is int ? raw : int.tryParse(raw?.toString() ?? '');
    if (value == null) return null;
    return value >= 1 && value <= 10000 ? value : null;
  }

  /// 制作人员列表。单条缺 `role` / `name` 时不抛——一部作品里混着几条脏记录，
  /// 不该让整个详情解析失败；空壳条目由 [WorkStaff.isEmpty] 在界面侧滤掉。
  static List<WorkStaff>? parseStaff(Object? raw) {
    if (raw is! List) return null;
    final items = raw
        .whereType<Map<String, dynamic>>()
        .map(WorkStaff.fromJson)
        .where((e) => !e.isEmpty)
        .toList(growable: false);
    return items;
  }

  /// 角色与声优列表，容错策略同 [parseStaff]。
  static List<WorkCharacter>? parseCharacters(Object? raw) {
    if (raw is! List) return null;
    return raw
        .whereType<Map<String, dynamic>>()
        .map(WorkCharacter.fromJson)
        .where((e) => !e.isEmpty)
        .toList(growable: false);
  }

  /// 序列化。离线缓存用（见 `HiveWorkCache`）。
  ///
  /// 与 [fromJson] 对称。[sourceUrl] 走 [parseSourceUrl] 归一：
  /// 缓存里存一个不合规的地址没有意义，解析侧也会把它挡掉。
  Map<String, dynamic> toJson() => {
    'work_id': workId,
    'work_type': workType.value,
    'title': title,
    'title_original': titleOriginal,
    'aliases': aliases,
    'media': media,
    'episodes': episodes,
    'summary': summary,
    'release_year': releaseYear,
    'cover_url': coverUrl,
    'tags': (tags == null || tags!.isEmpty) ? null : tags,
    'main_rating': mainRating?.toJson(),
    'staff': staff?.map((e) => e.toJson()).toList(),
    'characters': characters?.map((e) => e.toJson()).toList(),
    'studios': (studios == null || studios!.isEmpty) ? null : studios,
    'source': source,
    'source_id': sourceId,
    'source_url': sourceUrl,
    'updated_at': updatedAt?.toUtc().toIso8601String(),
  };

  @override
  String toString() => 'Work($workId, $title)';
}
