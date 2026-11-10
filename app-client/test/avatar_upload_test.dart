import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/data/models/account_user.dart';
import 'package:otaku_app/data/models/remote_config.dart';
import 'package:otaku_app/features/auth/auth_controller.dart';
import 'package:otaku_app/features/config/feature_flags.dart';
import 'package:otaku_app/features/profile/avatar_data_source.dart';
import 'package:otaku_app/features/profile/avatar_picker.dart';
import 'package:otaku_app/features/profile/profile_data_source.dart';
import 'package:otaku_app/features/profile/profile_edit_page.dart';
import 'package:otaku_app/features/profile/user_profile.dart';
import 'package:otaku_app/shared/widgets/user_avatar.dart';

/// 合法的最小 PNG（1×1 透明）。必须是**真的**：`FileImage` 会实际读文件并解码，
/// 路径不存在或字节非法都会在 ImageStream 上报错，把测试拖红。
const String _png1x1 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpe'
    'qz8AAAAASUVORK5CYII=';

/// 头像：选图 → 预览 → 上传（`POST /api/me/account/avatar`）。
///
/// 钉四件事：
/// 1. 没选图时没有「保存头像」，选了才出现；
/// 2. 点「保存头像」真的调用**恰好一次**上传，成功后清掉预览；
/// 3. **429 的提示带「N 秒后再试」**——说「上传失败」用户会立刻再点，
///    把 1 分钟 1 次的限流撞得更久；
/// 4. 已有头像时给「移除」，点下去真的删。
void main() {
  late Directory tmpDir;
  late String avatarPath;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('otaku_avatar_test');
    final file = File('${tmpDir.path}/avatar.png')
      ..writeAsBytesSync(base64Decode(_png1x1));
    avatarPath = file.path;
  });

  tearDown(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  testWidgets('没选图时只有「更换」，没有「保存头像」', (tester) async {
    await tester.pumpWidget(_host(picker: _FakeAvatarPicker(path: avatarPath)));
    await tester.pumpAndSettle();

    expect(find.text('更换'), findsOneWidget);
    expect(find.text('保存头像'), findsNothing);
    expect(find.text('没上传时用昵称首字生成色块。'), findsOneWidget);
  });

  testWidgets('选完图出现预览与「保存头像」，此时不写任何资料', (tester) async {
    final picker = _FakeAvatarPicker(path: avatarPath);
    final source = _RecordingProfileDataSource();
    await tester.pumpWidget(_host(picker: picker, source: source));
    await tester.pumpAndSettle();

    await tester.tap(find.text('更换'));
    await tester.pumpAndSettle();

    expect(picker.calls, 1);
    expect(find.text('保存头像'), findsOneWidget);
    expect(find.text('已选择图片，点「保存头像」上传。'), findsOneWidget);

    final avatar = tester.widget<UserAvatar>(find.byType(UserAvatar));
    expect(avatar.previewImage, isNotNull, reason: '选完就该看到新图');
    expect(source.updates, 0, reason: '选图只是本地预览，不该碰资料');
  });

  testWidgets('开关关着（默认）：点「保存头像」只弹说明，一次上传都不发', (tester) async {
    final uploader = _FakeAvatarDataSource();
    await tester.pumpWidget(
      _host(
        picker: _FakeAvatarPicker(path: avatarPath),
        uploader: uploader,
        enabled: false,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('更换'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存头像'));
    await tester.pumpAndSettle();

    expect(find.text('暂时无法设置头像'), findsOneWidget);
    expect(uploader.uploads, 0, reason: '开关关着不该写任何数据');
    // 预览保留：用户仍能看到自己选的那张图。
    expect(find.text('保存头像'), findsOneWidget);

    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
  });

  testWidgets('点「保存头像」真上传一次，成功后清掉预览', (tester) async {
    final uploader = _FakeAvatarDataSource();
    await tester.pumpWidget(
      _host(picker: _FakeAvatarPicker(path: avatarPath), uploader: uploader),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('更换'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存头像'));
    await tester.pumpAndSettle();

    expect(uploader.uploads, 1);
    expect(find.text('头像已更新'), findsOneWidget);
    // 上传成功、真图已写进资料，预览撤掉、按钮回到「更换」。
    expect(find.text('保存头像'), findsNothing);
    expect(find.text('更换'), findsOneWidget);
  });

  testWidgets('429：提示带「N 秒后再试」，不说「上传失败」', (tester) async {
    final uploader = _FakeAvatarDataSource(
      failWith: const ApiException(
        code: ApiErrorCode.rateLimited,
        message: '',
        statusCode: 429,
        retryAfter: Duration(seconds: 42),
      ),
    );
    await tester.pumpWidget(
      _host(picker: _FakeAvatarPicker(path: avatarPath), uploader: uploader),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('更换'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存头像'));
    await tester.pumpAndSettle();

    expect(find.textContaining('42 秒'), findsOneWidget);
    expect(find.textContaining('上传失败'), findsNothing);
    // 失败后保留预览：用户可以稍后重试，不用重新选图。
    expect(find.text('保存头像'), findsOneWidget);
  });

  testWidgets('已有头像时给「移除」，点下去真的删', (tester) async {
    final uploader = _FakeAvatarDataSource();
    await tester.pumpWidget(
      _host(
        picker: _FakeAvatarPicker(path: null),
        uploader: uploader,
        source: _RecordingProfileDataSource(
          initial: const UserProfile(avatarUrl: 'https://cdn.test/old.webp'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('移除'), findsOneWidget);
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();

    expect(uploader.deletes, 1);
    expect(find.text('头像已移除'), findsOneWidget);
  });

  testWidgets('用户取消选图：不进入预览', (tester) async {
    final picker = _FakeAvatarPicker(path: null);
    await tester.pumpWidget(_host(picker: picker));
    await tester.pumpAndSettle();

    await tester.tap(find.text('更换'));
    await tester.pumpAndSettle();

    expect(picker.calls, 1);
    expect(find.text('保存头像'), findsNothing);
    expect(find.text('更换'), findsOneWidget);
  });

  testWidgets('点「取消」清掉预览，回到「更换」', (tester) async {
    await tester.pumpWidget(_host(picker: _FakeAvatarPicker(path: avatarPath)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('更换'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('保存头像'), findsNothing);
    expect(find.text('更换'), findsOneWidget);
    expect(
      tester.widget<UserAvatar>(find.byType(UserAvatar)).previewImage,
      isNull,
    );
  });

  testWidgets('选择器报错时给提示，不假装选到了', (tester) async {
    await tester.pumpWidget(
      _host(picker: _FakeAvatarPicker(throwOnPick: true)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('更换'));
    await tester.pumpAndSettle();

    expect(find.text('没能读取图片，换一张试试'), findsOneWidget);
    expect(find.text('保存头像'), findsNothing);
  });
}

Widget _host({
  required AvatarPicker picker,
  ProfileDataSource? source,
  AvatarDataSource? uploader,
  /// `feature.avatar_upload` 开关。默认**打开**：大部分用例验的是「功能可用时」
  /// 的行为；「默认关」的那条由 `enabled: false` 单独覆盖。
  bool enabled = true,
}) {
  final container = ProviderContainer(
    overrides: [
      avatarPickerProvider.overrideWithValue(picker),
      avatarDataSourceProvider.overrideWithValue(
        uploader ?? _FakeAvatarDataSource(),
      ),
      profileDataSourceProvider.overrideWithValue(
        source ?? _RecordingProfileDataSource(),
      ),
      authControllerProvider.overrideWith(_SignedInAuth.new),
      featureFlagsProvider.overrideWithValue(
        FeatureFlags(
          RemoteConfig(
            version: 1,
            values: <String, dynamic>{'feature.avatar_upload': enabled},
          ),
        ),
      ),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      routerConfig: GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const ProfileEditPage()),
        ],
      ),
    ),
  );
}

class _FakeAvatarPicker implements AvatarPicker {
  _FakeAvatarPicker({this.path, this.throwOnPick = false});

  /// `null` = 用户取消。
  final String? path;
  final bool throwOnPick;
  int calls = 0;

  @override
  Future<String?> pickImage() async {
    calls++;
    if (throwOnPick) throw StateError('boom');
    return path;
  }
}

class _FakeAvatarDataSource implements AvatarDataSource {
  _FakeAvatarDataSource({this.failWith});

  /// 非空时 `upload` 抛它（用来验 429 的文案）。
  final ApiException? failWith;
  int uploads = 0;
  int deletes = 0;

  @override
  Future<String> upload(String filePath) async {
    uploads++;
    final error = failWith;
    if (error != null) throw error;
    return 'https://cdn.test/avatar.webp';
  }

  @override
  Future<void> delete() async {
    deletes++;
  }
}

/// 只关心「有没有被写过」，所以记次数而不是存值。
class _RecordingProfileDataSource implements ProfileDataSource {
  _RecordingProfileDataSource({UserProfile initial = const UserProfile()})
    : _current = initial;

  int updates = 0;
  UserProfile _current;

  @override
  Future<UserProfile> fetch() async => _current;

  @override
  Future<UserProfile> update({
    required String? displayName,
    required String? bio,
  }) async {
    updates++;
    _current = UserProfile(displayName: displayName, bio: bio);
    return _current;
  }
}

class _SignedInAuth extends AuthController {
  @override
  AuthState build() => const AuthState(
    status: AuthStatus.signedIn,
    user: AccountUser(userId: 'U-test', username: 'alice'),
  );
}
