import 'package:flutter/foundation.dart';

/// 一条制作人员记录。契约 `WorkStaff`。
///
/// `role` / `name` 都是**来源原值**，平台不做职位归一——「总作画监督」不会
/// 被合并成「作画监督」。合并会丢信息，怎么展示由界面决定：
/// 按后端给的顺序平铺即可，不要自己重排或分组。
@immutable
class WorkStaff {
  const WorkStaff({required this.role, required this.name, this.personId});

  /// 职位（导演 / 脚本 / 音乐 / 作画监督 …），来源原值。
  final String role;

  /// 人名，来源原值。
  final String name;

  /// 人物实体标识。`null` = 这条来自纯文本解析、没有实体。
  ///
  /// 契约写明：Staff 侧实测 **0% 有值**，且人物页落地前一律 `null`，
  /// 客户端**不得**依赖它做跳转，也不得因为它为 `null` 就隐藏这条记录。
  /// 字段先占位是为了让界面提前布局，不是「马上就会填满」的承诺。
  final String? personId;

  factory WorkStaff.fromJson(Map<String, dynamic> json) {
    final role = json['role'];
    final name = json['name'];
    return WorkStaff(
      role: role is String ? role : '',
      name: name is String ? name : '',
      personId: json['person_id'] is String
          ? json['person_id'] as String
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'role': role,
    'name': name,
    'person_id': personId,
  };

  /// 职位和人名都空了才叫「没有内容」：`role` 缺失但有人名时仍要显示，
  /// 来源侧有些记录只给了人名。
  bool get isEmpty => role.isEmpty && name.isEmpty;

  @override
  String toString() => 'WorkStaff($role, $name)';
}
