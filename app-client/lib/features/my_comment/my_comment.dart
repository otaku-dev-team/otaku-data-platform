import 'package:flutter/foundation.dart';

import '../../data/models/work_summary.dart';

/// 「我的评论」一条，字段与契约 `MyComment`（`docs/openapi.yaml` §components）
/// 一一对应。列表由 `GET /api/me/comments` 返回，作者自己删掉的 `deleted`
/// 不会出现在这里。
///
/// 这是**展示模型**，不是接口 DTO 的转录：时间解成 [DateTime]、状态解成枚举，
/// 页面永远不用碰原始字符串。将来接真接口时映射只写在数据源层。
@immutable
class MyComment {
  const MyComment({
    required this.commentId,
    required this.workId,
    required this.body,
    required this.status,
    this.createdAt,
    this.editedAt,
    this.parentId,
    this.work,
  });

  final String commentId;

  /// 不透明字符串：只透传，不解析、不展示给用户。作品不可见时它仍在，
  /// 只是 [work] 为 null。
  final String workId;

  final String body;
  final MyCommentStatus status;

  /// `null` = 服务端没给时间，界面不显示时间行，不能当成「刚刚」。
  final DateTime? createdAt;

  /// 非空表示作者改过正文（站主隐藏 / 恢复不算编辑）。
  final DateTime? editedAt;

  /// 非空表示这是一条回复，指向顶层评论 id。
  final String? parentId;

  /// 内嵌作品卡片。作品后来下架 / 不可见时为 `null`——**评论正文照常返回**，
  /// 界面要给占位，不能把整行丢掉（否则用户会觉得「我明明发过」）。
  final WorkSummary? work;

  bool get isReply => parentId != null;

  factory MyComment.fromJson(Map<String, dynamic> json) {
    final commentId = json['comment_id'];
    final workId = json['work_id'];
    final body = json['body'];
    if (commentId is! String || commentId.isEmpty) {
      throw const FormatException('comment_id 缺失或为空');
    }
    if (workId is! String || workId.isEmpty) {
      throw const FormatException('work_id 缺失或为空');
    }

    final rawWork = json['work'];
    WorkSummary? work;
    if (rawWork is Map) {
      try {
        work = WorkSummary.fromJson(Map<String, dynamic>.from(rawWork));
      } on FormatException {
        // 作品摘要缺字段不该让整页评论崩掉：退化成「作品不可见」占位。
        work = null;
      }
    }

    return MyComment(
      commentId: commentId,
      workId: workId,
      body: body is String ? body : '',
      status: MyCommentStatus.fromValue(json['status']),
      createdAt: _parseDate(json['created_at']),
      editedAt: _parseDate(json['edited_at']),
      parentId: _nullableString(json['parent_id']),
      work: work,
    );
  }

  Map<String, dynamic> toJson() => {
    'comment_id': commentId,
    'work_id': workId,
    'body': body,
    'status': status.value,
    'created_at': createdAt?.toUtc().toIso8601String(),
    'edited_at': editedAt?.toUtc().toIso8601String(),
    'parent_id': parentId,
    'work': work?.toJson(),
  };

  static DateTime? _parseDate(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  static String? _nullableString(Object? raw) {
    if (raw is! String) return null;
    return raw.isEmpty ? null : raw;
  }

  @override
  String toString() => 'MyComment($commentId, ${status.value})';
}

/// 契约三态 + 一个兜底。与 [WorkType] 同口径：未知取值不抛异常，
/// 后端将来加状态时老客户端不会白屏。
enum MyCommentStatus {
  published('published', '已发布'),
  pending('pending', '审核中'),
  hidden('hidden', '已隐藏'),
  unknown('', '状态未知');

  const MyCommentStatus(this.value, this.label);

  final String value;

  /// 展示用中文名。
  final String label;

  static MyCommentStatus fromValue(Object? raw) {
    for (final status in MyCommentStatus.values) {
      if (status != MyCommentStatus.unknown && status.value == raw) {
        return status;
      }
    }
    return MyCommentStatus.unknown;
  }
}
