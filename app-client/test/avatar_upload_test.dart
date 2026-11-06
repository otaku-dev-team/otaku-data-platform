import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:otaku_app/data/models/account_user.dart';
import 'package:otaku_app/features/auth/auth_controller.dart';
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

/// 头像上传：选图 + 预览能跑，**保存不生效**。
///
/// 钉住四件事：
/// 1. 没选图时不出现「保存头像」，选了才出现；
/// 2. 点「保存头像」只弹「暂时无法设置头像」，**一次写入都没有**；
/// 3. 用户取消选图不留残影；
/// 4. 选择器报错给提示，不假装选到了。
///
/// 第 2 条是这一版的核心：假成功会让「头像没变」在真机上变成谜。
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
    expect(find.text('已选择图片，还没保存。'), findsOneWidget);

    final avatar = tester.widget<UserAvatar>(find.byType(UserAvatar));
    expect(avatar.previewImage, isNotNull, reason: '选完就该看到新图，不必等上传');
    expect(source.updates, 0, reason: '选图只是本地预览，不该碰数据源');
  });

  testWidgets('点「保存头像」只弹说明，一次写入都没有', (tester) async {
    final source = _RecordingProfileDataSource();
    await tester.pumpWidget(
      _host(picker: _FakeAvatarPicker(path: avatarPath), source: source),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('更换'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存头像'));
    await tester.pumpAndSettle();

    expect(find.text('暂时无法设置头像'), findsOneWidget);
    expect(find.textContaining('没有保存'), findsOneWidget);
    expect(source.updates, 0, reason: '这一版刻意不生效，任何写入都是 bug');
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

Widget _host({required AvatarPicker picker, ProfileDataSource? source}) {
  final container = ProviderContainer(
    overrides: [
      avatarPickerProvider.overrideWithValue(picker),
      profileDataSourceProvider.overrideWithValue(
        source ?? _RecordingProfileDataSource(),
      ),
      authControllerProvider.overrideWith(_SignedInAuth.new),
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

/// 只关心「有没有被写过」，所以记次数而不是存值。
class _RecordingProfileDataSource implements ProfileDataSource {
  int updates = 0;
  UserProfile _current = const UserProfile();

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
