import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/dio_client.dart';
import '../../core/storage/token_store.dart';
import '../datasources/auth_data_source.dart';
import '../datasources/auth_mock_data_source.dart';
import '../datasources/auth_remote_data_source.dart';
import '../models/account_user.dart';

/// 认证的门面。各层只管要「当前用户」，令牌存哪里、什么时候清由这里决定。
class AuthRepository {
  AuthRepository(this._dataSource, this._tokenStore);

  final AuthDataSource _dataSource;
  final TokenStore _tokenStore;

  /// 冷启动恢复会话，返回 `null` 表示需要登录。
  ///
  /// **只有服务端明确说令牌无效（401）才清本地令牌。** 断网时把令牌清掉，
  /// 等于用户一断网就被登出，重新联网还得再输一次密码。
  Future<AccountUser?> restoreSession() async {
    final token = await _tokenStore.read();
    if (token == null || token.isEmpty) return null;

    try {
      return await _dataSource.me(token);
    } on ApiException catch (error) {
      if (error.code == ApiErrorCode.unauthorized) {
        await _tokenStore.clear();
        return null;
      }
      // 网络/超时：令牌留着，这次按未登录处理，下次启动再试。
      rethrow;
    }
  }

  Future<AccountUser> login({
    required String username,
    required String password,
  }) async {
    final session = await _dataSource.login(
      username: username,
      password: password,
    );
    await _tokenStore.write(session.token);
    return session.user;
  }

  /// 站点授权登录：票据换平台会话。
  ///
  /// 与 [login] 的差别只在「凭据是什么」——拿到会话之后存令牌、返回用户，
  /// 两条路完全同构。**不缓存票据**：一次性、120 秒，落盘只会留下一个
  /// 已经不能用的秘密。
  Future<AccountUser> siteLogin(String ticket) async {
    final session = await _dataSource.siteLogin(ticket);
    await _tokenStore.write(session.token);
    return session.user;
  }

  /// 只清本地会话，不打服务端。
  ///
  /// 用于「令牌已被服务端判定无效」的场景：这时再去调 logout 只会再拿一个 401。
  Future<void> clearSession() => _tokenStore.clear();

  /// 退出登录：只结束**当前**会话，其他端不受影响（C9）。
  ///
  /// 服务端不可达也必须清本地，否则用户会「退不出去」——这是唯一一处
  /// 允许在写请求失败后仍然改本地状态的地方，因为它的语义是「本机不再使用」。
  Future<void> logout() async {
    final token = await _tokenStore.read();
    try {
      if (token != null && token.isNotEmpty) {
        await _dataSource.logout(token);
      }
    } on Object {
      // 忽略：本地清理由 finally 保证。
    } finally {
      await _tokenStore.clear();
    }
  }
}

/// 默认走 Mock；联调时加 `--dart-define=USE_MOCK=false` 切真实接口。
final authDataSourceProvider = Provider<AuthDataSource>((ref) {
  if (AppConfig.useMock) return AuthMockDataSource();
  return RemoteAuthDataSource(ref.watch(dioProvider));
});

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(
    ref.watch(authDataSourceProvider),
    ref.watch(tokenStoreProvider),
  );
});
