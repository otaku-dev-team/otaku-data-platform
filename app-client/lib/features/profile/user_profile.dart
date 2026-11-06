import 'package:flutter/foundation.dart';

/// 账号资料（#378 第一层）。
///
/// 刻意**不塞进 `AccountUser`**：那是登录接口 `User` 的映射，字段随契约走；
/// 而资料是可编辑的，契约还没定稿（`PUT /api/me/profile` 待 pyxz0 确认）。
/// 分开之后，接口形状变化时只改 `profile_data_source.dart`，登录链路一行不动。
///
/// 三个字段都可空，`null` 不是「空字符串」：昵称 null 表示回落 `username`，
/// 简介 null 表示没填，头像 null 表示用首字色块。空串在保存前归一为 null。
@immutable
class UserProfile {
  const UserProfile({this.displayName, this.bio, this.avatarUrl});

  /// 平台自设昵称。`null` = 回落到 `username`。
  final String? displayName;

  /// 个人简介。zm 拍板只做昵称 + 简介 + 头像，**不做性别/生日/所在地**
  /// （敏感个人信息，收益只是「和网站一样」）。
  final String? bio;

  /// 头像 URL。第二层（`POST /api/me/avatar`）落地前恒为 `null`；
  /// 留这个字段是为了第二层接上时不用再改组件签名。
  final String? avatarUrl;

  UserProfile copyWith({
    String? displayName,
    String? bio,
    String? avatarUrl,
    bool clearDisplayName = false,
    bool clearBio = false,
    bool clearAvatarUrl = false,
  }) {
    return UserProfile(
      displayName: clearDisplayName ? null : (displayName ?? this.displayName),
      bio: clearBio ? null : (bio ?? this.bio),
      avatarUrl: clearAvatarUrl ? null : (avatarUrl ?? this.avatarUrl),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is UserProfile &&
      other.displayName == displayName &&
      other.bio == bio &&
      other.avatarUrl == avatarUrl;

  @override
  int get hashCode => Object.hash(displayName, bio, avatarUrl);

  @override
  String toString() => 'UserProfile($displayName)';
}
