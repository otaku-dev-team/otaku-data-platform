import '../../core/network/api_exception.dart';
import '../models/account_user.dart';
import 'auth_data_source.dart';

/// 阶段 2 契约未定稿前的假认证源。
///
/// 只用来把登录流程、令牌持久化、退出登录的界面跑通，**不代表最终接口语义**：
/// - 任意非空用户名 + 非空密码都能登录；密码是 `wrong` 时返回 401 `INVALID_CREDENTIALS`；
/// - 令牌形如 `mock-token-<username>`，`me()` 从令牌里还原用户名，
///   这样重启后仍能验证「令牌被真的存下来了」。
class AuthMockDataSource implements AuthDataSource {
  AuthMockDataSource({this.delay = const Duration(milliseconds: 400)});

  final Duration delay;

  static const String _tokenPrefix = 'mock-token-';

  @override
  Future<AuthSession> login({
    required String username,
    required String password,
  }) async {
    await Future<void>.delayed(delay);

    final normalized = username.trim();
    if (normalized.isEmpty || password.isEmpty) {
      throw const ApiException(
        code: ApiErrorCode.badRequest,
        message: '请输入账号和密码',
        statusCode: 400,
      );
    }
    if (password == 'wrong') {
      throw invalidCredentials;
    }

    return AuthSession(
      token: '$_tokenPrefix$normalized',
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 30)),
      user: AccountUser(
        userId: 'mock-user-$normalized',
        username: normalized,
        displayName: null,
      ),
    );
  }

  @override
  Future<AccountUser> me(String token) async {
    await Future<void>.delayed(delay);

    if (!token.startsWith(_tokenPrefix) || token.length == _tokenPrefix.length) {
      throw const ApiException(
        code: ApiErrorCode.unauthorized,
        message: '登录已过期，请重新登录',
        statusCode: 401,
      );
    }

    final username = token.substring(_tokenPrefix.length);
    return AccountUser(
      userId: 'mock-user-$username',
      username: username,
      displayName: null,
    );
  }

  @override
  Future<void> logout(String token) async {
    await Future<void>.delayed(delay);
  }
}
