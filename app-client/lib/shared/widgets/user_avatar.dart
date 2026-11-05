import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// 账号头像：有 URL 显示图片，没有就退回**首字色块**。
///
/// 抽成公开组件是为了两处一致（个人空间身份卡 / 编辑资料页），
/// 也是给 #378 第二层留的接缝：头像上传落地后，调用方只要把
/// `User.avatar_url` 传进 [avatarUrl]，这里一行都不用改。
///
/// 三个刻意的取舍：
/// 1. **首字取显示名的第一个字**，不是 `username` 的首字——昵称本来就是
///    用户想被叫的名字，拿登录名当头像文字会让人觉得改了昵称没生效；
/// 2. 用 `characters` 而不是 `substring(0, 1)`：昵称里带 emoji 时后者会切出半个代理对；
/// 3. **不做缓存 / 不做占位骨架**：头像没值时本来就是零请求，加骨架只会闪一下。
class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.label,
    this.avatarUrl,
    this.radius = 26,
  });

  /// 显示名（昵称优先，没有则用户名）。
  final String label;

  /// 头像 URL。`null` / 空串 = 首字色块。
  final String? avatarUrl;

  final double radius;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasImage = avatarUrl != null && avatarUrl!.isNotEmpty;
    final trimmed = label.trim();
    final initial = trimmed.isEmpty
        ? null
        : trimmed.characters.first.toUpperCase();

    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.primaryContainer,
      foregroundColor: scheme.onPrimaryContainer,
      backgroundImage: hasImage ? NetworkImage(avatarUrl!) : null,
      child: hasImage
          ? null
          : (initial != null
              ? Text(
                  initial,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                )
              : const Icon(Icons.person_outline_rounded)),
    );
  }
}

/// 编辑页里用的大头像尺寸，和个人空间身份卡区分开。
const double kProfileEditAvatarRadius = Space.s5 * 2;
