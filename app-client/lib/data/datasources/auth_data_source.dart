import '../../core/network/api_exception.dart';
import '../models/account_user.dart';

/// 一次登录的结果。
///
/// 令牌是不透明字符串，客户端只负责保存与回传，**不解析内容、不做本地过期判断**——
/// 过期以服务端返回 `401 UNAUTHORIZED` 为准。
class AuthSession {
  const AuthSession({
    required this.token,
    required this.expiresAt,
    required this.user,
  });

  final String token;
  final DateTime expiresAt;
  final AccountUser user;

  factory AuthSession.fromJson(Map<String, dynamic> json) {
    final token = json['token'];
    final user = json['user'];
    if (token is! String || token.isEmpty) {
      throw const FormatException('token 缺失或为空');
    }
    if (user is! Map<String, dynamic>) {
      throw const FormatException('user 缺失');
    }
    final rawExpires = json['expires_at'];
    return AuthSession(
      token: token,
      expiresAt: DateTime.tryParse(rawExpires is String ? rawExpires : '') ??
          DateTime.now().toUtc(),
      user: AccountUser.fromJson(user),
    );
  }
}

/// 认证相关的服务端能力。
///
/// 对应的接口形状见 `docs/stage2-account-collection-contract.md` §4.1–§4.3，
/// **契约仍在评审（Issue #32）**，所以当前只有 Mock 实现。定稿后在这里补
/// `RemoteAuthDataSource`，其余各层不需要改。
abstract class AuthDataSource {
  Future<AuthSession> login({
    required String username,
    required String password,
  });

  /// 校验令牌并取当前用户。令牌无效/过期必须抛 [ApiErrorCode.unauthorized]。
  Future<AccountUser> me(String token);

  /// 撤销当前令牌。其他端的会话不受影响（C9）。
  Future<void> logout(String token);
}

/// 401 有两层含义，客户端必须按 `code` 区分：
/// - `INVALID_CREDENTIALS`：登录时账号密码不对，**不能清已有会话**；
/// - `UNAUTHORIZED`：令牌无效或过期，**应当清会话回登录页**。
const ApiException invalidCredentials = ApiException(
  code: ApiErrorCode.invalidCredentials,
  message: '账号或密码不正确',
  statusCode: 401,
);
