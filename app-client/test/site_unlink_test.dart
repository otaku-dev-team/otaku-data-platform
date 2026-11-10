import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/core/storage/token_store.dart';
import 'package:otaku_app/data/datasources/auth_data_source.dart';
import 'package:otaku_app/data/datasources/auth_mock_data_source.dart';
import 'package:otaku_app/data/datasources/auth_remote_data_source.dart';
import 'package:otaku_app/data/repositories/auth_repository.dart';
import 'package:otaku_app/features/auth/auth_controller.dart';
import 'package:otaku_app/features/auth/site_unlink_dialog.dart';

/// W1 三态②「断开与网站的连接」（`POST /api/auth/site-unlink`）。
///
/// 钉四件会静默出错的事：路径与 Bearer 头、成功后必须清本地令牌（服务端连
/// 当前会话一起撤）、平台账号不能误发请求、以及文案不能写「已立即吊销」。
void main() {
  group('数据源', () {
    test('POST /api/auth/site-unlink：带 Bearer、无请求体', () async {
      final stub = _Stub();
      await RemoteAuthDataSource(_dio(stub)).unlinkSite('tok-1');

      expect(stub.request.method, 'POST');
      expect(stub.request.path, '/api/auth/site-unlink');
      expect(stub.request.headers['Authorization'], 'Bearer tok-1');
      // 契约：无请求体。多发一个 {} 会被后端当成多余字段。
      expect(stub.request.data, isNull);
    });
  });

  group('控制器', () {
    late _MemoryTokenStore tokenStore;

    ProviderContainer createContainer({AuthDataSource? source}) {
      final container = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(tokenStore),
          authDataSourceProvider.overrideWithValue(
            source ?? AuthMockDataSource(delay: Duration.zero),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    Future<void> settle(ProviderContainer container) async {
      var state = container.read(authControllerProvider);
      for (var i = 0; i < 50 && state.status == AuthStatus.checking; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        state = container.read(authControllerProvider);
      }
    }

    setUp(() => tokenStore = _MemoryTokenStore());

    test('站点账号断开成功：回未登录、本地令牌清掉', () async {
      final container = createContainer();
      await settle(container);
      // Mock 的 siteLogin 返回 identity_source=otaku_site 的账号。
      await container
          .read(authControllerProvider.notifier)
          .siteLogin('ticket-1');
      expect(
        container.read(authControllerProvider).user?.isSiteIdentity,
        isTrue,
      );
      expect(tokenStore.token, isNotNull);

      final error = await container
          .read(authControllerProvider.notifier)
          .unlinkSite();

      expect(error, isNull);
      final state = container.read(authControllerProvider);
      expect(state.status, AuthStatus.signedOut);
      expect(state.user, isNull);
      // 服务端已撤销全部会话；本地令牌留着只会拿到 401。
      expect(tokenStore.token, isNull);
    });

    test('平台账号不发请求：返回 NOT_SITE_LINKED，登录态不动', () async {
      final container = createContainer();
      await settle(container);
      await container
          .read(authControllerProvider.notifier)
          .login('alice', 'secret');
      expect(
        container.read(authControllerProvider).user?.isSiteIdentity,
        isFalse,
      );

      final error = await container
          .read(authControllerProvider.notifier)
          .unlinkSite();

      expect(error?.code, ApiErrorCode.notSiteLinked);
      expect(container.read(authControllerProvider).status, AuthStatus.signedIn);
      expect(tokenStore.token, 'mock-token-alice');
    });

    test('服务端失败：返回异常，保持登录态（连接还在）', () async {
      final container = createContainer(source: _FailingUnlinkSource());
      await settle(container);
      await container
          .read(authControllerProvider.notifier)
          .siteLogin('ticket-2');

      final error = await container
          .read(authControllerProvider.notifier)
          .unlinkSite();

      expect(error?.code, ApiErrorCode.notSiteLinked);
      expect(container.read(authControllerProvider).status, AuthStatus.signedIn);
      expect(tokenStore.token, isNotNull);
    });
  });

  group('确认对话框', () {
    testWidgets('文案写清「保留数据 / 1 小时 / 不是注销」，不写立即吊销', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => confirmSiteUnlink(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('断开与网站的连接？'), findsOneWidget);
      expect(find.textContaining('收藏、浏览记录与评论都保留'), findsOneWidget);
      expect(find.textContaining('1 小时'), findsOneWidget);
      expect(find.textContaining('不是注销账号'), findsOneWidget);
      // 平台调不动站点 revoke，「立即吊销」是不成立的承诺。
      expect(find.textContaining('立即吊销'), findsNothing);
    });
  });
}

class _MemoryTokenStore implements TokenStore {
  String? token;

  @override
  Future<String?> read() async => token;

  @override
  Future<void> write(String value) async => token = value;

  @override
  Future<void> clear() async => token = null;
}

/// 站点登录成功、但断开失败的替身（模拟 409 或网络错误）。
class _FailingUnlinkSource extends AuthMockDataSource {
  _FailingUnlinkSource() : super(delay: Duration.zero);

  @override
  Future<void> unlinkSite(String token) async {
    throw const ApiException(
      code: ApiErrorCode.notSiteLinked,
      message: '当前账号不是站点账号，无需断开',
      statusCode: 409,
    );
  }
}

class _Stub {
  late RequestOptions request;

  void handle(RequestOptions options, RequestInterceptorHandler handler) {
    request = options;
    handler.resolve(
      Response<void>(requestOptions: options, statusCode: 204),
    );
  }
}

Dio _dio(_Stub stub) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test.local'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => stub.handle(options, handler),
    ),
  );
  return dio;
}
