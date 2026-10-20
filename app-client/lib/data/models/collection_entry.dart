import 'package:flutter/foundation.dart';

import 'work_type.dart';

/// 观看状态。契约（`data-contract.md` §7）只允许这三个值；
/// **「未收藏」不是一种状态，而是记录不存在**。
enum CollectionStatus {
  want('want', '想看'),
  watching('watching', '在看'),
  watched('watched', '看过');

  const CollectionStatus(this.value, this.label);

  /// 与接口一致的取值。
  final String value;

  /// 界面文案。
  final String label;

  /// 非法取值直接抛，不静默降级：契约要求 `status` 有问题时服务端返回 400，
  /// 客户端解析时同样不该把脏数据当成「没状态」放过去。
  static CollectionStatus parse(Object? raw) {
    for (final status in values) {
      if (status.value == raw) return status;
    }
    throw FormatException('未知的收藏状态: $raw');
  }
}

/// 一条收藏记录。字段与 `GET /api/me/collections` 的列表项对齐。
///
/// 列表接口**不返回 `summary`**（与阶段 1 的作品列表同一个理由），
/// 需要简介请按 `work_id` 拉详情。
@immutable
class CollectionEntry {
  const CollectionEntry({
    required this.workId,
    required this.workType,
    required this.title,
    this.coverUrl,
    this.status,
    this.updatedAt,
  });

  final String workId;
  final WorkType workType;
  final String title;

  /// 平台代理地址；`null` 表示无封面，界面走占位图。
  final String? coverUrl;

  /// `null` = 已收藏但未设状态。与「未收藏」是两件事。
  final CollectionStatus? status;

  final DateTime? updatedAt;

  CollectionEntry withStatus(CollectionStatus? status) {
    return CollectionEntry(
      workId: workId,
      workType: workType,
      title: title,
      coverUrl: coverUrl,
      status: status,
      updatedAt: updatedAt,
    );
  }

  factory CollectionEntry.fromJson(Map<String, dynamic> json) {
    final workId = json['work_id'];
    final title = json['title'];
    if (workId is! String || workId.isEmpty) {
      throw const FormatException('work_id 缺失或为空');
    }
    if (title is! String || title.isEmpty) {
      throw const FormatException('title 缺失或为空');
    }

    final coverUrl = json['cover_url'];
    final rawStatus = json['status'];
    final rawUpdatedAt = json['updated_at'];
    return CollectionEntry(
      workId: workId,
      workType: WorkType.fromValue(json['work_type']),
      title: title,
      coverUrl: coverUrl is String && coverUrl.isNotEmpty ? coverUrl : null,
      status: rawStatus == null ? null : CollectionStatus.parse(rawStatus),
      updatedAt: rawUpdatedAt is String ? DateTime.tryParse(rawUpdatedAt) : null,
    );
  }

  @override
  String toString() => 'CollectionEntry($workId, ${status?.value ?? 'none'})';
}
