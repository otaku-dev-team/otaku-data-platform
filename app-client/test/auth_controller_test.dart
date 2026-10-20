import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/core/storage/token_store.dart';
import 'package:otaku_app/data/datasources/auth_mock_data_source.dart';
import 'package:otaku_app/data/repositories/auth_repository.dart';
import 'package:otaku_app/features/auth/auth_controller.dart';

/// 内存令牌存储。真实实现要平台通道，单测里调不了。
class _MemoryTokenStore implements TokenStore {
  String? token;

  @override
  Future<String?> read() async => token;

  @override
  Future<void> write(String value) async => token = value;

  @override
  Future<void> clear() async => token = null;
}

void main() {
  late _MemoryTokenStore tokenStore;

  ProviderContainer createContainer() {
    final container = ProviderContainer(
      overrides: [
        tokenStoreProvider.overrideWithValue(tokenStore),
        authDataSourceProvider.overrideWithValue(
          AuthMockDataSource(delay: Duration.zero),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// `AuthController.build` 用微任务恢复会话，等它跑完。
  ///
  /// 必须先 `read` 一次触发 build，否则 provider 还没被创建、微任务也不会被调度。
  Future<AuthState> settle(ProviderContainer container) async {
    var state = container.read(authControllerProvider);
    for (var i = 0; i < 50 && state.status == AuthStatus.checking; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      state = container.read(authControllerProvider);
    }
    return state;
  }

  setUp(() {
    tokenStore = _MemoryTokenStore();
  });

  test('没有令牌时是未登录，不是加载中', () async {
    final container = createContainer();
    final state = await settle(container);

    expect(state.status, AuthStatus.signedOut);
    expect(state.user, isNull);
  });

  test('登录成功：状态变已登录，令牌真的落库', () async {
    final container = createContainer();
    await settle(container);

    final ok = await container
        .read(authControllerProvider.notifier)
        .login('alice', 'secret');

    expect(ok, isTrue);
    final state = container.read(authControllerProvider);
    expect(state.status, AuthStatus.signedIn);
    expect(state.user?.username, 'alice');
    expect(tokenStore.token, 'mock-token-alice');
  });

  test('密码错：回到未登录并带错误码，不写令牌', () async {
    final container = createContainer();
    await settle(container);

    final ok = await container
        .read(authControllerProvider.notifier)
        .login('alice', 'wrong');

    expect(ok, isFalse);
    final state = container.read(authControllerProvider);
    expect(state.status, AuthStatus.signedOut);
    // 401 有两种 code，登录失败必须是 INVALID_CREDENTIALS 而不是 UNAUTHORIZED，
    // 否则全局 401 拦截会把其他端的会话一起清掉。
    expect(state.error?.code, ApiErrorCode.invalidCredentials);
    expect(tokenStore.token, isNull);
  });

  test('已有令牌：冷启动直接恢复登录态', () async {
    tokenStore.token = 'mock-token-bob';
    final container = createContainer();
    final state = await settle(container);

    expect(state.status, AuthStatus.signedIn);
    expect(state.user?.username, 'bob');
  });

  test('令牌无效：清掉本地令牌并回未登录', () async {
    tokenStore.token = 'garbage';
    final container = createContainer();
    final state = await settle(container);

    expect(state.status, AuthStatus.signedOut);
    expect(tokenStore.token, isNull);
  });

  test('退出登录：只清当前令牌', () async {
    tokenStore.token = 'mock-token-alice';
    final container = createContainer();
    await settle(container);

    await container.read(authControllerProvider.notifier).logout();

    expect(container.read(authControllerProvider).status, AuthStatus.signedOut);
    expect(tokenStore.token, isNull);
  });
}
