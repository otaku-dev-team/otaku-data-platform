import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:otaku_app/data/models/account_user.dart';
import 'package:otaku_app/features/auth/auth_controller.dart';
import 'package:otaku_app/features/profile/profile_data_source.dart';
import 'package:otaku_app/features/profile/profile_edit_page.dart';
import 'package:otaku_app/features/profile/user_profile.dart';

/// #378 第一层：编辑资料表单。
///
/// 钉住的是「用户动作 → 数据入口」这条链，不碰真接口：
/// 未登录给引导、空串归一为 null、保存成功后回退、失败不假装成功。
void main() {
  testWidgets('未登录时显示登录引导，不给表单', (tester) async {
    final source = _FakeProfileDataSource();
    await tester.pumpWidget(_host(source: source, signedIn: false));
    await tester.pumpAndSettle();

    expect(find.text('登录后编辑'), findsOneWidget);
    expect(find.text('保存'), findsNothing);
  });

  testWidgets('登录后可编辑，头像没 URL 时是首字色块', (tester) async {
    final source = _FakeProfileDataSource();
    await tester.pumpWidget(_host(source: source));
    await tester.pumpAndSettle();

    expect(find.text('编辑资料'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    expect(find.byType(TextFormField), findsNWidgets(2));

    final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
    expect(avatar.backgroundImage, isNull);
    // 首字取显示名，昵称没设时回落 username 的 A。
    expect(find.text('A'), findsWidgets);
  });

  testWidgets('保存把空串归一为 null，成功后回退', (tester) async {
    final source = _FakeProfileDataSource();
    await tester.pumpWidget(_host(source: source));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), '  深夜考据派  ');
    await tester.enterText(find.byType(TextFormField).at(1), '  ');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(source.saved, isNotNull);
    expect(source.saved!.displayName, '深夜考据派');
    expect(source.saved!.bio, isNull);
    expect(find.text('资料已保存'), findsOneWidget);
  });

  testWidgets('保存失败给提示，不假装成功', (tester) async {
    final source = _FakeProfileDataSource(failOnUpdate: true);
    await tester.pumpWidget(_host(source: source));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), '新昵称');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('保存失败，请稍后重试'), findsOneWidget);
    expect(find.text('资料已保存'), findsNothing);
    // 表单还在，按钮恢复可点。
    expect(find.text('保存'), findsOneWidget);
  });
}

Widget _host({
  required _FakeProfileDataSource source,
  bool signedIn = true,
}) {
  final container = ProviderContainer(
    overrides: [
      profileDataSourceProvider.overrideWithValue(source),
      authControllerProvider.overrideWith(
        signedIn ? _SignedInAuth.new : _SignedOutAuth.new,
      ),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      routerConfig: GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const ProfileEditPage(),
          ),
        ],
      ),
    ),
  );
}

class _FakeProfileDataSource implements ProfileDataSource {
  _FakeProfileDataSource({this.failOnUpdate = false});

  final bool failOnUpdate;
  UserProfile? saved;
  UserProfile _current = const UserProfile();

  @override
  Future<UserProfile> fetch() async => _current;

  @override
  Future<UserProfile> update({
    required String? displayName,
    required String? bio,
  }) async {
    if (failOnUpdate) throw StateError('boom');
    _current = UserProfile(displayName: displayName, bio: bio);
    saved = _current;
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

class _SignedOutAuth extends AuthController {
  @override
  AuthState build() => const AuthState(status: AuthStatus.signedOut);
}
