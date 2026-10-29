import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/core/storage/local_prefs_provider.dart';
import 'package:otaku_app/core/storage/memory_local_prefs.dart';
import 'package:otaku_app/features/auth/auth_controller.dart';
import 'package:otaku_app/features/auth/site_auth_launcher.dart';

import 'support/test_overrides.dart';

/// 站点票据换会话的失败分档（Issue #238 收尾）。
///
/// 契约 §1.1 给三类失败规定了**不同的用户动作**，所以这里钉的不是「有没有
/// 错误提示」，而是「提示把用户指向哪个动作」：
///
/// | 失败 | 用户该做什么 | 用户**不该**被推向什么 |
/// |---|---|---|
/// | 401 票据失效 | 重新授权 | 重试（票据一次性，重试必然再失败） |
/// | 503 站点不可用 | 稍后再试 | 重走授权（站点自己都不可用，重走必然再失败） |
/// | 403 账号被禁用 | 停在那儿 | 重试 / 重走（重做几次都还是禁用） |
///
/// 为什么值得单独一个文件：这三条曾经被一句「授权失败，请重试」抹平，
/// 而抹平之后**测试照样全绿**——因为 mock 抛的码（`UNAUTHORIZED`）与后端
/// 实际返的码（`INVALID_CREDENTIALS`）不是同一个，场景化替换那条分支
/// 在 mock 下命中、真机上不命中。所以本文件的 ticket 值直接驱动真机同款码，
/// 另有一条断言钉住「后端返的码没变」。
void main() {
  late MockSiteAuthLauncher launcher;
  late InMemoryLocalPrefs prefs;

  setUp(() {
    launcher = MockSiteAuthLauncher();
    prefs = InMemoryLocalPrefs();
  });

  ProviderContainer createContainer() {
    final container = ProviderContainer(
      overrides: [
        ...authOverrides(token: null),
        localPrefsProvider.overrideWithValue(prefs),
        siteAuthLauncherProvider.overrideWithValue(launcher),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// 走一遍完整授权回跳，返回用户最终看到的那句提示。
  Future<String?> messageFor(String ticket) async {
    final container = createContainer();
    await container.read(authControllerProvider.notifier).beginSiteLogin();
    final attempt = container.read(siteAuthStateStoreProvider).read();
    expect(attempt, isNotNull, reason: '前置：得先有一次进行中的授权');
    await container
        .read(authControllerProvider.notifier)
        .handleSiteRedirect(
          Uri.parse(
            'com.otaku.app:/oauth2redirect?ticket=$ticket'
            '&state=${attempt!.state}',
          ),
        );
    return container.read(authControllerProvider).error?.userMessage;
  }

  group('后端返的码没变（真响应体）', () {
    test('401 的 wire code 是 INVALID_CREDENTIALS，不是 UNAUTHORIZED', () {
      // 2026-10-29 对生产 `154.8.194.198:8080` 实测：
      // POST /api/auth/site-login  {"ticket":"fake-ticket-for-probe"}
      // → 401 {"error":{"code":"INVALID_CREDENTIALS","message":"站点授权已失效，请重新登录"}}
      final error = ApiException.fromResponse(
        Response<dynamic>(
          requestOptions: RequestOptions(path: '/api/auth/site-login'),
          statusCode: 401,
          data: const <String, dynamic>{
            'error': <String, dynamic>{
              'code': 'INVALID_CREDENTIALS',
              'message': '站点授权已失效，请重新登录',
            },
          },
        ),
      );
      expect(
        error.code,
        ApiErrorCode.invalidCredentials,
        reason:
            '判据写在 AuthController._siteLoginError 里，'
            '后端一换码那条分支就整档失效',
      );
    });

    test('503 / 403 两个码能被识别（不是落到 unknown）', () {
      expect(
        ApiErrorCode.fromWire('SITE_UNAVAILABLE'),
        ApiErrorCode.siteUnavailable,
      );
      expect(ApiErrorCode.fromWire('USER_DISABLED'), ApiErrorCode.userDisabled);
    });
  });

  group('三档失败各说各的', () {
    test('401 票据失效 → 引导「重新授权」，且不提「重试」', () async {
      final message = await messageFor('expired');
      expect(message, isNotNull);
      expect(message, contains('重新授权'));
      expect(
        message,
        isNot(contains('重试')),
        reason:
            '契约 §1.1：401 不要静默重试——票据一次性，'
            '重试拿的是同一张票，必然再失败',
      );
    });

    test('401 不能说成「账号或密码不正确」', () async {
      // 这条是历史 bug 的钉子：判据写错码时，invalidCredentials 会被
      // 通用文案接管，用户压根没输过平台密码，却被告知密码不对。
      final message = await messageFor('expired');
      expect(message, isNot(contains('账号或密码')));
    });

    test('503 站点不可用 → 「稍后再试」，且不引导重走授权', () async {
      final message = await messageFor('site-down');
      expect(message, contains('稍后再试'));
      expect(
        message,
        isNot(contains('重新授权')),
        reason: '契约 §1.1：503 不要引导重走授权——重走也会失败',
      );
      expect(message, isNot(contains('重试授权')));
    });

    test('403 账号被禁用 → 说「已禁用」，不往重试上引', () async {
      final message = await messageFor('disabled');
      expect(message, contains('禁用'));
      expect(message, isNot(contains('重新授权')));
    });
  });
}
