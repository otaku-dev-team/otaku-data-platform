import 'package:flutter/foundation.dart';

import 'collection_entry.dart';

/// 单条收藏状态，对应 `PUT` / `PATCH` / 单条查询的响应。
///
/// **和 [CollectionEntry] 不是一回事**：契约里这个对象只有 `work_id`、`collected`、
/// `status` 和两个时间戳，**没有 `title` / `work_type` / `cover_url`**。
/// 所以它只能用来更新「状态」，不能拿去替换列表里的整条记录——
/// 否则列表会显示成 work_id 或空白标题。
///
/// `collected: false` 是正常结果（未收藏），只有作品本身不存在才是 404。
@immutable
class CollectionState {
  const CollectionState({
    required this.workId,
    required this.collected,
    this.status,
    this.createdAt,
    this.updatedAt,
  });

  final String workId;
  final bool collected;

  /// `null` 有两种含义：未收藏，或已收藏但未设状态——由 [collected] 区分。
  final CollectionStatus? status;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// 把状态合进列表里已有的那条记录，作品信息保持原样。
  CollectionEntry mergeInto(CollectionEntry entry) {
    assert(entry.workId == workId, '合并的两条记录必须是同一个作品');
    return entry.withStatus(status);
  }

  factory CollectionState.fromJson(Map<String, dynamic> json) {
    final workId = json['work_id'];
    if (workId is! String || workId.isEmpty) {
      throw const FormatException('work_id 缺失或为空');
    }
    final collected = json['collected'];
    if (collected is! bool) {
      throw const FormatException('collected 缺失或类型错误');
    }

    final rawStatus = json['status'];
    final rawCreatedAt = json['created_at'];
    final rawUpdatedAt = json['updated_at'];
    return CollectionState(
      workId: workId,
      collected: collected,
      status: rawStatus == null ? null : CollectionStatus.parse(rawStatus),
      createdAt: rawCreatedAt is String ? DateTime.tryParse(rawCreatedAt) : null,
      updatedAt: rawUpdatedAt is String ? DateTime.tryParse(rawUpdatedAt) : null,
    );
  }

  @override
  String toString() =>
      'CollectionState($workId, collected=$collected, ${status?.value ?? 'none'})';
}
