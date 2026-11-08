import 'package:flutter/foundation.dart';

import 'work_type.dart';

/// 观看状态。契约（`data-contract.md` §7）允许这四个值；
/// **「未收藏」不是一种状态，而是记录不存在**。
///
/// ⚠️ `dropped`（抛弃，#496）与「取消收藏」是两件事：
/// 取消收藏会删行、信号消失；抛弃保留记录，画像里记**负权重**、
/// 且不进九维分母（`PersonaDimensions`）。所以它必须是一个真实状态，
/// 不能折成删除，也不能当成 `null`（未设状态）。
///
/// ⚠️ **服务端加取值时客户端必须跟着加**：三态时代的 [parse] 遇到
/// 未知取值直接抛，一条 `dropped` 会让整个收藏页解析失败（#540 上线后
/// 的真实故障）。列表接口的枚举已经是 `[want, watching, watched, dropped, none]`，
/// 契约再扩取值时先查这里。
enum CollectionStatus {
  want('want', '想看'),
  watching('watching', '在看'),
  watched('watched', '看过'),
  dropped('dropped', '抛弃');

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

  /// 离线缓存用的序列化。与 [fromJson] 成对，字段对齐同一个契约。
  ///
  /// **省略 null 而不是写 `null`**：缓存是「上一次服务端给的样子」，
  /// 写不写 null 解析结果一样，但少两个键能让缓存体积小一点；
  /// 反过来，[fromJson] 对 null 一律按「没有」处理，两边始终对得上。
  Map<String, dynamic> toJson() => {
    'work_id': workId,
    'work_type': workType.value,
    'title': title,
    if (coverUrl != null) 'cover_url': coverUrl,
    if (status != null) 'status': status!.value,
    if (updatedAt != null) 'updated_at': updatedAt!.toUtc().toIso8601String(),
  };

  @override
  String toString() => 'CollectionEntry($workId, ${status?.value ?? 'none'})';
}
