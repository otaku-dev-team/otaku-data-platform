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
  });

  final String userId;
  final String username;
  final String? displayName;

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
    return AccountUser(
      userId: userId,
      username: username,
      displayName: displayName is String && displayName.isNotEmpty
          ? displayName
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AccountUser &&
      other.userId == userId &&
      other.username == username &&
      other.displayName == displayName;

  @override
  int get hashCode => Object.hash(userId, username, displayName);

  @override
  String toString() => 'AccountUser($userId, $username)';
}
