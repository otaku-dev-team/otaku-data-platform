import 'package:flutter/foundation.dart';

/// 一条角色与声优记录。契约 `WorkCharacter`。
///
/// 角色名与声优名都是来源原值文本，不做跨源归一。
@immutable
class WorkCharacter {
  const WorkCharacter({
    required this.name,
    required this.actor,
    this.characterType,
    this.personId,
  });

  /// 角色名。
  final String name;

  /// 声优名（来源原值，含日文原文）。
  final String actor;

  /// 主役 / 配角。**实测 84% 为空**（来源不分主配角），所以界面上：
  /// - 不显示「未知类型」这类补出来的文案；
  /// - 不按类型分组——分组会撑出一个巨大的「未知」桶。
  final String? characterType;

  /// 人物实体标识。与 [WorkStaff.personId] 不同，这一侧实测 **100% 有值**；
  /// 但人物页属 B2、本期范围外，所以当前同样不做跳转。
  final String? personId;

  factory WorkCharacter.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final actor = json['actor'];
    final type = json['character_type'];
    return WorkCharacter(
      name: name is String ? name : '',
      actor: actor is String ? actor : '',
      characterType: type is String && type.trim().isNotEmpty ? type : null,
      personId: json['person_id'] is String
          ? json['person_id'] as String
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'actor': actor,
    'character_type': characterType,
    'person_id': personId,
  };

  bool get isEmpty => name.isEmpty && actor.isEmpty;

  @override
  String toString() => 'WorkCharacter($name, $actor)';
}
