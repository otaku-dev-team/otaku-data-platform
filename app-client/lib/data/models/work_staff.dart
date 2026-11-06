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
  /// 契约写明：Staff 侧实测 **0% 有值**。人物页已落地（#455）后，非空即可点；
  /// 为 `null` 时**不得隐藏这一条**，只是不可点。
  /// 主创那一侧要等 v3 数据集把 `pname:` 弱关联键写进来（#362）。
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
