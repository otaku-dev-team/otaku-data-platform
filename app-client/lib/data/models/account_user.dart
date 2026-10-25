import 'package:flutter/foundation.dart';

/// 当前登录账号。
///
/// `user_id` 是平台内部标识，客户端**只当不透明字符串**：不解析、不做数值比较，
/// 也不出现在任何请求路径里（一律由令牌推导）。
@immutable
class AccountUser {
  const AccountUser({
    required this.userId,
    required this.username,
    this.displayName,
    this.identitySource,
  });

  final String userId;
  final String username;
  final String? displayName;

  /// 身份来源：`otaku_site` = 来源站账号；`null` = 平台账号。
  ///
  /// **后端暂不下发这个字段**（#147 待确认清单第 2 项），所以现在恒为 null；
  /// 加它是为了让「账号菜单显示身份来源」「该不该静默重走授权」有地方读，
  /// 不改变任何现有行为——后端不返回时一切照旧。
  final String? identitySource;

  /// 是否来源站身份。
  bool get isSiteIdentity => identitySource != null;

  /// 界面上优先显示昵称，没有就回落用户名。
  String get label =>
      (displayName != null && displayName!.isNotEmpty) ? displayName! : username;

  factory AccountUser.fromJson(Map<String, dynamic> json) {
    final userId = json['user_id'];
    final username = json['username'];
    if (userId is! String || userId.isEmpty) {
      throw const FormatException('user_id 缺失或为空');
    }
    if (username is! String || username.isEmpty) {
      throw const FormatException('username 缺失或为空');
    }
    final displayName = json['display_name'];
    final identitySource = json['identity_source'];
    return AccountUser(
      userId: userId,
      username: username,
      displayName: displayName is String && displayName.isNotEmpty
          ? displayName
          : null,
      // 认不出来的值一律当平台账号：身份来源只影响「显示什么、要不要重走授权」，
      // 猜错最坏是多提示一次重新登录，不该让用户登不进来。
      identitySource: identitySource is String && identitySource.isNotEmpty
          ? identitySource
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AccountUser &&
      other.userId == userId &&
      other.username == username &&
      other.displayName == displayName &&
      other.identitySource == identitySource;

  @override
  int get hashCode =>
      Object.hash(userId, username, displayName, identitySource);

  @override
  String toString() => 'AccountUser($userId, $username)';
}
