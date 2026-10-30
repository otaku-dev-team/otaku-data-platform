import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/core/network/session_expiry.dart';
import 'package:otaku_app/core/storage/local_prefs_provider.dart';
import 'package:otaku_app/core/storage/memory_local_prefs.dart';
import 'package:otaku_app/features/auth/auth_controller.dart';
import 'package:otaku_app/features/auth/login_page.dart';
import 'package:otaku_app/features/auth/site_auth_launcher.dart';
import 'package:otaku_app/features/auth/site_auth_state.dart';

import 'support/test_overrides.dart';

/// 站点授权全链的行为测试。
///
/// 深链接、进程回收、票据过期这些都不该等真机——用 Mock launcher 把回跳喂进来，
/// 就能在单测里把每条分支走完。
void main() {
  late MockSiteAuthLauncher launcher;
  late InMemoryLocalPrefs prefs;

  setUp(() {
    launcher = MockSiteAuthLauncher();
    prefs = InMemoryLocalPrefs();
  });

  ProviderContainer createContainer({SiteAuthLauncher? withLauncher}) {
    final container = ProviderContainer(
      overrides: [
        ...authOverrides(token: null),
        localPrefsProvider.overrideWithValue(prefs),
        siteAuthLauncherProvider.overrideWithValue(withLauncher ?? launcher),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// 走一遍「开始授权」，返回本地存下的 attempt。
  Future<SiteAuthAttempt> begin(ProviderContainer c) async {
    await c.read(authControllerProvider.notifier).beginSiteLogin();
    final attempt = c.read(siteAuthStateStoreProvider).read();
    expect(attempt, isNotNull, reason: '开始授权必须先落盘 state');
    return attempt!;
  }

  Uri redirectUri(String ticket, String state) =>
      Uri.parse('com.otaku.app:/oauth2redirect?ticket=$ticket&state=$state');

  group('开始授权', () {
    test('生成 state、落盘、打开系统浏览器，三者用同一个 state', () async {
      final c = createContainer();
      final attempt = await begin(c);

      expect(launcher.openCalls, 1);
      expect(launcher.lastState, attempt.state);
      expect(c.read(authControllerProvider).submitting, isTrue,
          reason: '等回跳期间界面应该在等待态');
    });

    test('打不开浏览器时要说出来，并清掉这次尝试', () async {
      final broken = _BrokenLauncher();
      final c = createContainer(withLauncher: broken);
      await c.read(authControllerProvider.notifier).beginSiteLogin();

      final state = c.read(authControllerProvider);
      expect(state.error?.userMessage, contains('打不开授权页面'));
      expect(c.read(siteAuthStateStoreProvider).read(), isNull,
          reason: '没打开成的授权不该留着 state 等一个不会来的回跳');
    });

    test('用户在授权页返回：清掉等待态，按钮不再转圈', () async {
      final c = createContainer();
      await begin(c);
      expect(c.read(authControllerProvider).submitting, isTrue,
          reason: '等回跳期间是等待态');

      c.read(authControllerProvider.notifier).cancelSiteLogin();

      final state = c.read(authControllerProvider);
      expect(state.submitting, isFalse,
          reason: '取消后必须回到可点状态，否则只能杀后台');
      expect(state.error, isNull, reason: '主动取消不是失败，不该弹错误');
    });
  });

  group('回跳处理', () {
    test('state 一致 → 登录成功，且是站点身份', () async {
      final c = createContainer();
      final attempt = await begin(c);

      final ok = await c
          .read(authControllerProvider.notifier)
          .handleSiteRedirect(redirectUri('ticket-1', attempt.state));

      expect(ok, isTrue);
      final auth = c.read(authControllerProvider);
      expect(auth.status, AuthStatus.signedIn);
      expect(auth.user?.isSiteIdentity, isTrue);
      expect(auth.user?.identitySource, 'otaku_site');
      expect(c.read(siteAuthStateStoreProvider).read(), isNull,
          reason: '票据一次性，用掉就必须清');
    });

    test('state 不符 → 「登录状态校验失败」，不登录', () async {
      final c = createContainer();
      await begin(c);

      final ok = await c
          .read(authControllerProvider.notifier)
          .handleSiteRedirect(redirectUri('ticket-1', '别人伪造的 state'));

      expect(ok, isFalse);
      final auth = c.read(authControllerProvider);
      expect(auth.status, AuthStatus.signedOut);
      expect(auth.error?.userMessage, contains('登录状态校验失败'));
      expect(c.read(siteAuthStateStoreProvider).read(), isNull);
    });

    test('过期 → 「授权已过期，请重新授权」（与失败分开说）', () async {
      final c = createContainer();
      await begin(c);
      // 把开始时刻改到很久以前，模拟用户在浏览器里逛了十分钟。
      await prefs.write(
        'site_auth_state',
        '{"state":"s","started_at":"2020-01-01T00:00:00.000Z"}',
      );

      final ok = await c
          .read(authControllerProvider.notifier)
          .handleSiteRedirect(redirectUri('ticket-1', 's'));

      expect(ok, isFalse);
      expect(c.read(authControllerProvider).error?.userMessage, contains('授权已过期'));
    });

    test('回跳没带 ticket → 单独一条错误', () async {
      final c = createContainer();
      final attempt = await begin(c);

      final ok = await c
          .read(authControllerProvider.notifier)
          .handleSiteRedirect(
            Uri.parse('com.otaku.app:/oauth2redirect?state=${attempt.state}'),
          );

      expect(ok, isFalse);
      expect(
        c.read(authControllerProvider).error?.userMessage,
        contains('授权没有返回票据'),
      );
    });

    test('没有进行中的授权 → 安静结束，不弹错误', () async {
      final c = createContainer();

      final ok = await c
          .read(authControllerProvider.notifier)
          .handleSiteRedirect(redirectUri('ticket-1', 'whatever'));

      expect(ok, isFalse);
      expect(c.read(authControllerProvider).error, isNull,
          reason: '可能是别的 App 在试同一个 scheme，不该打扰用户');
    });

    test('票据被用过（重放）→ 401，引导「重新授权」而不是「重试」', () async {
      final c = createContainer();
      final first = await begin(c);
      await c
          .read(authControllerProvider.notifier)
          .handleSiteRedirect(redirectUri('ticket-once', first.state));
      // 另一次授权拿同一个票据：站点侧票据是一次性的，平台后端归一后返 401。
      final second = await begin(c);

      final ok = await c
          .read(authControllerProvider.notifier)
          .handleSiteRedirect(redirectUri('ticket-once', second.state));

      expect(ok, isFalse);
      // 契约 §1.1：401 的用户动作是**重走一次授权**，不是拿同一张票重试
      // ——票据一次性，重试必然再失败。三档分档的完整钉子在
      // `site_login_error_test.dart`。
      expect(
        c.read(authControllerProvider).error?.userMessage,
        contains('重新授权'),
      );
    });
  });

  group('401 兜底', () {
    test('站点身份账号先静默重走一次授权，不清会话', () async {
      final c = createContainer();
      final attempt = await begin(c);
      await c
          .read(authControllerProvider.notifier)
          .handleSiteRedirect(redirectUri('ticket-a', attempt.state));
      expect(c.read(authControllerProvider).status, AuthStatus.signedIn);

      c.read(sessionExpiryProvider.notifier).notifyExpired();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(launcher.openCalls, 2, reason: '第一次是登录，第二次是静默重走');
      expect(c.read(authControllerProvider).status, AuthStatus.signedIn,
          reason: '重走期间不清会话——用户只是看到浏览器闪了一下');
    });

    test('平台账号 401 直接清会话，不重走授权', () async {
      final c = createContainer();
      final ok = await c
          .read(authControllerProvider.notifier)
          .login('alice', 'alice1234');
      expect(ok, isTrue);

      c.read(sessionExpiryProvider.notifier).notifyExpired();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(launcher.openCalls, 0, reason: '重走授权解决不了平台账号的 401');
      expect(c.read(authControllerProvider).status, AuthStatus.signedOut);
    });
  });

  group('登录页呈现', () {
    Widget wrap(ProviderContainer c) => UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: LoginPage()),
    );

    testWidgets('支持授权时：主按钮 + 折叠的平台表单', (tester) async {
      final c = createContainer();
      await tester.pumpWidget(wrap(c));
      await tester.pump();

      expect(find.text('用 Otaku 账号登录'), findsOneWidget);
      expect(find.text('使用平台账号登录'), findsOneWidget);
      expect(find.text('会打开网站授权页，密码只在网站输入'), findsOneWidget);
      // 表单默认收起：主路径是站点授权
      expect(find.widgetWithText(TextField, '账号'), findsNothing);

      await tester.tap(find.text('使用平台账号登录'));
      await tester.pump();
      expect(find.widgetWithText(TextField, '账号'), findsOneWidget);
      expect(find.widgetWithText(TextField, '密码'), findsOneWidget);
    });

    testWidgets('不支持授权时：只有平台表单，不显示站点入口', (tester) async {
      final c = createContainer(withLauncher: const UnsupportedSiteAuthLauncher());
      await tester.pumpWidget(wrap(c));
      await tester.pump();

      expect(find.text('用 Otaku 账号登录'), findsNothing);
      expect(find.text('使用平台账号登录'), findsNothing);
      expect(find.widgetWithText(TextField, '账号'), findsOneWidget);
    });
  });
}

/// 打不开浏览器的替身。
class _BrokenLauncher implements SiteAuthLauncher {
  @override
  bool get supported => true;

  @override
  Stream<String> get redirects => const Stream<String>.empty();

  @override
  Stream<void> get cancelled => const Stream<void>.empty();

  @override
  Future<bool> openAuthorize({required String state}) async => false;
}
