import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/desktop_nav_shell.dart';
import '../../shared/widgets/user_avatar.dart';
import '../auth/auth_controller.dart';
import 'avatar_data_source.dart';
import 'avatar_picker.dart';
import 'profile_data_source.dart';
import 'user_profile.dart';

/// 编辑资料（#378 第一层，二级页 `/me/edit`）。
///
/// zm 01:16 拍板的第一层：昵称 + 简介 + 首字色块头像兜底；
/// **不做性别 / 生日 / 所在地**（敏感个人信息）。
///
/// ## 头像：选图 → 预览 → 上传
///
/// 2026-11-07：`POST /api/me/account/avatar` 已上线（#509），这一段不再是
/// 「有功能但不启用」——选完图点「保存头像」会真上传；服务端居中裁方、
/// 缩放到 512×512 并重编码后返回直出地址。
///
/// 三个约束收在 `avatar_data_source.dart` 里：2MB 上限、按魔数校验格式、
/// 同一用户 1 分钟只能传 1 次。超限是 `429` 带 `Retry-After`，界面要说
/// 「N 秒后再试」而不是「上传失败」——后者用户会立刻再点一次。
///
/// ## 两个刻意的行为
///
/// 1. **空串归一为 `null`**，不是存一个空字符串。昵称 `null` 才能回落
///    `username`，否则会出现「昵称是空的」这种谁也解释不清的状态；
/// 2. 保存成功后**回退到上一页**并显示 SnackBar，不原地留着表单——
///    留着会让人以为没保存上、再点一次。
class ProfileEditPage extends ConsumerWidget {
  const ProfileEditPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final profile = ref.watch(profileProvider);

    return DesktopNavShell(
      child: Scaffold(
        appBar: AppBar(title: const Text('编辑资料')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppLayout.listMaxWidth),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                AppLayout.pagePadding,
                Space.s3,
                AppLayout.pagePadding,
                Space.s6,
              ),
              children: [
                if (!auth.isSignedIn)
                  const _SignInPrompt()
                else
                  profile.when(
                    loading: () => const Padding(
                      padding: EdgeInsets.all(Space.s6),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                    error: (error, stack) => _LoadError(
                      onRetry: () => ref.invalidate(profileProvider),
                    ),
                    // 资料变了就重建表单，避免 controller 里留着上一次的值。
                    data: (value) => _ProfileForm(
                      key: ValueKey<UserProfile>(value),
                      initial: value,
                      displayLabel: auth.user!.label,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SignInPrompt extends StatelessWidget {
  const _SignInPrompt();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.s4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('登录后编辑', style: theme.textTheme.titleMedium),
            const SizedBox(height: Space.s1),
            Text(
              '昵称与简介属于这个账号，登录后可在设备间同步。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Space.s3),
            FilledButton(
              onPressed: () => context.push(RoutePaths.login),
              child: const Text('登录'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.s4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('资料没能读出来'),
            const SizedBox(height: Space.s2),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

class _ProfileForm extends ConsumerStatefulWidget {
  const _ProfileForm({
    super.key,
    required this.initial,
    required this.displayLabel,
  });

  final UserProfile initial;

  /// 当前显示名（昵称优先，回落 username），用于头像首字与占位文案。
  final String displayLabel;

  @override
  ConsumerState<_ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends ConsumerState<_ProfileForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _bioController;
  bool _saving = false;

  /// 已经选好、但**没有上传**的本地图片。
  ///
  /// 非空 = 界面上正在预览一张还没保存的图。让它变空的方式只有两种：
  /// 用户点「取消」，或离开这一页（表单按 [UserProfile] 重建）。
  File? _pendingAvatar;

  /// 头像上传 / 删除进行中。
  ///
  /// 上传不可重复触发：服务端限制同一用户 1 分钟 1 次，连点两下等于
  /// 主动撞限流。
  bool _savingAvatar = false;

  /// 与 zm 给的 DDL 一致：`display_name VARCHAR(32)` / `bio VARCHAR(200)`。
  static const int _maxName = 32;
  static const int _maxBio = 200;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initial.displayName);
    _bioController = TextEditingController(text: widget.initial.bio);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Space.s4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      UserAvatar(
                        label: widget.displayLabel,
                        avatarUrl: widget.initial.avatarUrl,
                        // 本地预览优先：选完立刻看到新图，不必等上传回来。
                        previewImage: _pendingAvatar == null
                            ? null
                            : FileImage(_pendingAvatar!),
                        radius: kProfileEditAvatarRadius,
                      ),
                      const SizedBox(width: Space.s3),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('头像', style: theme.textTheme.titleSmall),
                            const SizedBox(height: Space.s1),
                            Text(
                              _pendingAvatar != null
                                  ? '已选择图片，点「保存头像」上传。'
                                  : (widget.initial.avatarUrl != null
                                        ? '已设置头像。'
                                        : '没上传时用昵称首字生成色块。'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_pendingAvatar == null)
                        Wrap(
                          alignment: WrapAlignment.end,
                          children: [
                            TextButton(
                              onPressed: _savingAvatar ? null : _pickAvatar,
                              child: const Text('更换'),
                            ),
                            if (widget.initial.avatarUrl != null)
                              TextButton(
                                onPressed: _savingAvatar ? null : _removeAvatar,
                                child: const Text('移除'),
                              ),
                          ],
                        )
                      else
                        TextButton(
                          onPressed: _savingAvatar
                              ? null
                              : () => setState(() => _pendingAvatar = null),
                          child: const Text('取消'),
                        ),
                    ],
                  ),
                  if (_pendingAvatar != null) ...[
                    const SizedBox(height: Space.s3),
                    FilledButton.tonal(
                      onPressed: _savingAvatar ? null : _saveAvatar,
                      child: _savingAvatar
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('保存头像'),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: Space.s4),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Space.s4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      labelText: '昵称',
                      hintText: widget.displayLabel,
                      helperText: '留空则显示用户名',
                      counterText: '${_nameController.text.length}/$_maxName',
                    ),
                    maxLength: _maxName,
                    textInputAction: TextInputAction.next,
                    onChanged: (_) => setState(() {}),
                    validator: (value) =>
                        (value != null && value.trim().length > _maxName)
                        ? '昵称最多 $_maxName 字'
                        : null,
                  ),
                  const SizedBox(height: Space.s2),
                  TextFormField(
                    controller: _bioController,
                    decoration: const InputDecoration(
                      labelText: '简介',
                      hintText: '写点什么介绍自己',
                      alignLabelWithHint: true,
                    ),
                    maxLength: _maxBio,
                    maxLines: 3,
                    minLines: 2,
                    validator: (value) =>
                        (value != null && value.trim().length > _maxBio)
                        ? '简介最多 $_maxBio 字'
                        : null,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: Space.s4),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
          const SizedBox(height: Space.s2),
          Text(
            '昵称与简介只用于展示；性别、生日、所在地不收集。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 打开系统选择器挑一张图，选完进本地预览（**不上传**）。
  Future<void> _pickAvatar() async {
    String? path;
    try {
      path = await ref.read(avatarPickerProvider).pickImage();
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没能读取图片，换一张试试')));
      return;
    }
    // null = 用户取消了：保持原样，别把上一次的预览也一起清掉。
    if (path == null || !mounted) return;
    final picked = File(path);
    setState(() => _pendingAvatar = picked);
  }

  /// 上传选好的头像。
  ///
  /// 成功后 `invalidate(profileProvider)`，整个表单会按新的 [UserProfile] 重建
  /// （`_ProfileForm` 的 key 是 `ValueKey<UserProfile>`）。代价是**未保存的昵称 /
  /// 简介改动会丢**——但反过来（不刷新）会让头像「传了没反应」，那个更难解释。
  /// 提示语说「头像已更新」，用户也就知道刚刚发生了一次保存。
  Future<void> _saveAvatar() async {
    final file = _pendingAvatar;
    if (file == null || _savingAvatar) return;
    setState(() => _savingAvatar = true);

    try {
      await ref.read(avatarDataSourceProvider).upload(file.path);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _savingAvatar = false);
      // `userMessage` 已经按 code 本地化；429 会带「请 N 秒后再试」。
      // 换成「上传失败」，用户只会立刻再点一次，把限流撞得更久。
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.userMessage)));
      return;
    } on Object {
      if (!mounted) return;
      setState(() => _savingAvatar = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('头像上传失败，请稍后重试')));
      return;
    }

    ref.invalidate(profileProvider);
    if (!mounted) return;
    setState(() {
      _savingAvatar = false;
      // 上传成功、真图已经写进资料，本地预览可以撤了。
      _pendingAvatar = null;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('头像已更新')));
  }

  /// 移除头像。服务端幂等（本来没有也 204），所以不用先查一次。
  /// 移除后回落到昵称首字色块。
  Future<void> _removeAvatar() async {
    if (_savingAvatar) return;
    setState(() => _savingAvatar = true);

    try {
      await ref.read(avatarDataSourceProvider).delete();
    } on Object {
      if (!mounted) return;
      setState(() => _savingAvatar = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没能移除头像，请稍后重试')));
      return;
    }

    ref.invalidate(profileProvider);
    if (!mounted) return;
    setState(() => _savingAvatar = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('头像已移除')));
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final name = _nameController.text.trim();
    final bio = _bioController.text.trim();
    try {
      await ref.read(profileDataSourceProvider).update(
        displayName: name.isEmpty ? null : name,
        bio: bio.isEmpty ? null : bio,
      );
    } on Object {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('保存失败，请稍后重试')));
      return;
    }

    ref.invalidate(profileProvider);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('资料已保存')));
    // 回到个人空间，让身份卡立刻显示新昵称。
    if (context.canPop()) context.pop();
  }
}
