import 'package:flutter/foundation.dart';

import 'work_summary.dart';

/// 一个人的详情（契约 `PersonDetail`，#455）。
///
/// 形状照来源站的 `cast_detail()`：**按作品合并**——同一部作品既可能挂「导演」
/// 又可能配音「鹿目圆」，拆成两条会让页面出现两张一模一样的卡片。
/// 所以一条 [PersonCredit] 里同时带 `characters` 与 `roles`，两者都可能为空。
///
/// `personId` 是**不透明字符串**：现在库里是裸数字，切 v3 数据集后是
/// `bgm:` / `pname:` / `cname:` 前缀。不解析、不比大小、不自己拼。
@immutable
class PersonDetail {
  const PersonDetail({
    required this.personId,
    required this.personName,
    this.entityType,
    this.works = const <PersonCredit>[],
    this.castCount = 0,
    this.creditCount = 0,
  });

  final String personId;
  final String personName;

  /// 来源侧实体类型原值（`person` / `company` / `null`）。
  /// 只用于文案（「参与作品」还是「配音作品」），不做逻辑分支。
  final String? entityType;

  /// 参与作品，服务端已按评分倒序。可能一两百条（实测某声优 193 部）。
  final List<PersonCredit> works;

  /// 配音作品数 / 制作作品数（按作品去重，已排除不可见的）。
  final int castCount;
  final int creditCount;

  bool get hasWorks => works.isNotEmpty;

  factory PersonDetail.fromJson(Map<String, dynamic> json) {
    final rawWorks = json['works'];
    final works = <PersonCredit>[];
    if (rawWorks is List) {
      for (final item in rawWorks) {
        if (item is! Map<String, dynamic>) continue;
        final credit = PersonCredit.tryFromJson(item);
        // 单条作品解析失败就跳过：一条脏数据不该让整页 404。
        if (credit != null) works.add(credit);
      }
    }
    return PersonDetail(
      personId: _str(json['person_id']),
      personName: _str(json['person_name']),
      entityType: _nullableStr(json['entity_type']),
      works: List<PersonCredit>.unmodifiable(works),
      castCount: _int(json['cast_count']),
      creditCount: _int(json['credit_count']),
    );
  }
}

/// 一部参与作品：作品本体 + 在这部作品里的两类身份。
@immutable
class PersonCredit {
  const PersonCredit({
    required this.work,
    this.characters = const <String>[],
    this.roles = const <String>[],
  });

  final WorkSummary work;

  /// 配音角色名；只做制作时为空。
  final List<String> characters;

  /// 制作职责（导演 / 脚本 / 原画…，来源原值）；只配音时为空。
  final List<String> roles;

  bool get hasCharacters => characters.isNotEmpty;
  bool get hasRoles => roles.isNotEmpty;

  /// 作品本体解析失败（缺 `work_id` / `title`）时返回 `null`，由调用方跳过。
  static PersonCredit? tryFromJson(Map<String, dynamic> json) {
    final rawWork = json['work'];
    if (rawWork is! Map<String, dynamic>) return null;
    final WorkSummary work;
    try {
      work = WorkSummary.fromJson(rawWork);
    } on FormatException {
      return null;
    }
    return PersonCredit(
      work: work,
      characters: _strings(json['characters']),
      roles: _strings(json['roles']),
    );
  }
}

String _str(Object? value) => value is String ? value : '';

String? _nullableStr(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

int _int(Object? value) => value is int ? value : 0;

List<String> _strings(Object? raw) {
  if (raw is! List) return const <String>[];
  final out = <String>[];
  for (final item in raw) {
    if (item is String && item.isNotEmpty) out.add(item);
  }
  return List<String>.unmodifiable(out);
}
