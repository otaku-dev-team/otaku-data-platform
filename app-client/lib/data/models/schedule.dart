import 'package:flutter/foundation.dart';

/// 每日新番档期的一页数据。对应后端 `GET /api/schedule`。
///
/// 按星期分组返回而不是平铺列表：页面布局就是按天分组，
/// 服务端分好组，客户端少一层 groupBy，也少传 8 次星期字段。
@immutable
class SchedulePageData {
  const SchedulePageData({
    required this.season,
    required this.seasons,
    required this.groups,
  });

  /// 本次返回的季度；库里没有任何数据时为 null。
  final String? season;

  /// 全部可用季度（新的在前），给「切换季度」用。
  final List<String> seasons;

  /// 固定 8 组（周一…周日 + 待定）；空季度时组内为空。
  final List<ScheduleGroup> groups;

  bool get isEmpty => groups.every((group) => group.items.isEmpty);

  ScheduleGroup? groupOf(int? weekday) {
    for (final group in groups) {
      if (group.weekday == weekday) return group;
    }
    return null;
  }

  factory SchedulePageData.fromJson(Map<String, dynamic> json) {
    final rawGroups = json['groups'];
    return SchedulePageData(
      season: json['season'] is String ? json['season'] as String : null,
      seasons: (json['seasons'] is List)
          ? (json['seasons'] as List).whereType<String>().toList(growable: false)
          : const <String>[],
      groups: rawGroups is List
          ? [
              for (final group in rawGroups)
                if (group is Map)
                  ScheduleGroup.fromJson(Map<String, dynamic>.from(group)),
            ]
          : const <ScheduleGroup>[],
    );
  }
}

@immutable
class ScheduleGroup {
  const ScheduleGroup({
    required this.weekday,
    required this.label,
    required this.items,
  });

  /// 1..7 周一..周日；null = 待定。
  final int? weekday;

  final String label;

  final List<ScheduleEntry> items;

  factory ScheduleGroup.fromJson(Map<String, dynamic> json) {
    return ScheduleGroup(
      weekday: json['weekday'] is int ? json['weekday'] as int : null,
      label: json['label'] is String ? json['label'] as String : '',
      items: (json['items'] is List)
          ? [
              for (final item in json['items'] as List)
                if (item is Map)
                  ScheduleEntry.fromJson(Map<String, dynamic>.from(item)),
            ]
          : const <ScheduleEntry>[],
    );
  }
}

/// 一条档期。
@immutable
class ScheduleEntry {
  const ScheduleEntry({
    required this.scheduleId,
    required this.title,
    this.seasonCode,
    this.titleCn,
    this.titleJp,
    this.weekday,
    this.broadcastTime,
    this.broadcastNote,
    this.workType,
    this.tags,
    this.imageUrl,
    this.platforms,
    this.sourceUrl,
    this.workId,
  });

  final String scheduleId;

  /// 展示用标题：主标题优先（后端保证非空）。
  final String title;

  final String? seasonCode;
  final String? titleCn;
  final String? titleJp;

  /// 1..7；null = 待定。
  final int? weekday;

  /// 放送时刻（站点常缺，缺失时看 [broadcastNote]）。
  final String? broadcastTime;

  /// 放送备注原文，如「4/7周一深夜；(全12话)」。
  final String? broadcastNote;

  /// 站点作品类型描述，如「游戏改编动画」。
  final String? workType;

  /// `null` 与 `[]` 同义：都不渲染标签区。
  final List<String>? tags;

  /// B 站外链封面。**可能全部加载失败**（站点未本地化），
  /// 界面必须走占位图降级，不能当成一定有图。
  final String? imageUrl;

  /// 播放平台 [{name, url}]，原样透传。
  final List<SchedulePlatform>? platforms;

  final String? sourceUrl;

  /// 命中本地作品时为其 work_id；null = 未收录，**不可跳转**。
  final String? workId;

  bool get isLinked => workId != null && workId!.isNotEmpty;

  factory ScheduleEntry.fromJson(Map<String, dynamic> json) {
    return ScheduleEntry(
      scheduleId: json['schedule_id'] is String ? json['schedule_id'] as String : '',
      title: (json['title_main'] is String && (json['title_main'] as String).isNotEmpty)
          ? json['title_main'] as String
          : (json['title_cn'] as String? ?? ''),
      seasonCode: json['season_code'] as String?,
      titleCn: json['title_cn'] as String?,
      titleJp: json['title_jp'] as String?,
      weekday: json['weekday'] is int ? json['weekday'] as int : null,
      broadcastTime: json['broadcast_time'] as String?,
      broadcastNote: json['broadcast_note'] as String?,
      workType: json['work_type'] as String?,
      tags: (json['work_tags'] is List)
          ? (json['work_tags'] as List).whereType<String>().toList(growable: false)
          : null,
      imageUrl: json['image_url'] as String?,
      platforms: (json['platforms'] is List)
          ? [
              for (final platform in json['platforms'] as List)
                if (platform is Map)
                  SchedulePlatform.fromJson(Map<String, dynamic>.from(platform)),
            ]
          : null,
      sourceUrl: json['source_url'] as String?,
      workId: json['work_id'] as String?,
    );
  }
}

@immutable
class SchedulePlatform {
  const SchedulePlatform({this.name, this.url});

  final String? name;
  final String? url;

  factory SchedulePlatform.fromJson(Map<String, dynamic> json) {
    return SchedulePlatform(
      name: json['name'] as String?,
      url: json['url'] as String?,
    );
  }
}
