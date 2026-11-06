import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/desktop_nav_shell.dart';
import '../../shared/widgets/user_avatar.dart';
import '../auth/auth_controller.dart';
import 'avatar_picker.dart';
import 'profile_data_source.dart';
import 'user_profile.dart';

/// 编辑资料（#378 第一层，二级页 `/me/edit`）。
///
/// zm 01:16 拍板的第一层：昵称 + 简介 + 首字色块头像兜底；
/// **不做性别 / 生日 / 所在地**（敏感个人信息）。
///
/// ## 头像：能选、能看，但**存不了**
///
/// 选图与预览已经可用（系统文件选择器 → 本地预览），唯独最后一步
/// 「保存头像」只弹说明、不写任何数据。原因不是偷懒：`openapi.yaml` 里
/// `avatar` 零命中，既没有 `PUT /api/me/profile` 也没有上传端点，
/// 存储形态（本地还是对象存储、URL 谁签发）也没定。
///
/// 这是「有功能但不启用」而不是「没做」：接口落地时只需把
/// `_saveAvatar` 里的对话框换成「上传 → 拿 URL → update → invalidate」，
/// 选图、预览、组件三处一行都不用改。
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
                        // 选完就立刻看到新图，不必等上传——因为上传这一步
                        // 现在**根本走不到**（见 _saveAvatar）。
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
                              _pendingAvatar == null
                                  ? '没上传时用昵称首字生成色块。'
                                  : '已选择图片，还没保存。',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_pendingAvatar == null)
                        TextButton(
                          onPressed: _pickAvatar,
                          child: const Text('更换'),
                        )
                      else
                        TextButton(
                          onPressed: () =>
                              setState(() => _pendingAvatar = null),
                          child: const Text('取消'),
                        ),
                    ],
                  ),
                  if (_pendingAvatar != null) ...[
                    const SizedBox(height: Space.s3),
                    // 这一步**刻意不生效**：点下去只弹说明、不写任何数据。
                    // 详见 _saveAvatar 的注释。
                    FilledButton.tonal(
                      onPressed: _saveAvatar,
                      child: const Text('保存头像'),
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

  /// 「保存头像」——**这里就是刻意的「有功能但不生效」那一刀**。
  ///
  /// 选图、预览都能跑，唯独此处不写任何数据：
  ///
  /// - 契约里 `avatar` 零命中（`docs/openapi.yaml` 搜不到这个字段），
  ///   既没有 `PUT /api/me/profile`，也没有上传端点；
  /// - 存储形态还没定：本地文件还是对象存储、URL 谁签发、换头像时旧图
  ///   要不要删——这些不先定就上传，等于先欠一笔删不掉的债。
  ///
  /// 所以只把「还没开放」说清楚，并明确告诉用户这张图**没有保存**——
  /// 比做一个假成功、回头发现头像没变要好。
  ///
  /// 接口落地时把这段换成：上传 → 拿 URL → `update(avatarUrl: url)`
  /// → `invalidate(profileProvider)`。上面的选图与预览一行都不用改。
  Future<void> _saveAvatar() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('暂时无法设置头像'),
        content: const Text(
          '选图和预览已经可以用，但上传还没开放。\n\n'
          '这张图只在本机预览，没有保存；当前仍使用昵称首字生成的头像。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
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
