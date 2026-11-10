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
/// 接口形状见 `docs/stage2-account-collection-contract.md` §4.1–§4.3（已定稿并实现）。
/// 真接口走 [`auth_remote_data_source.dart`](auth_remote_data_source.dart)，
/// Mock 走 [`auth_mock_data_source.dart`](auth_mock_data_source.dart)，由 `AppConfig.useMock` 切换。
abstract class AuthDataSource {
  Future<AuthSession> login({
    required String username,
    required String password,
  });

  /// 校验令牌并取当前用户。令牌无效/过期必须抛 [ApiErrorCode.unauthorized]。
  Future<AccountUser> me(String token);

  /// 用站点授权票据换平台会话（#147 §2：`POST /api/auth/site-login`）。
  ///
  /// 票据一次性、120 秒。平台后端归一站点错误码后返回 401——客户端只按
  /// 「授权失败，请重试」呈现，不区分是过期、被用过还是 secret 错：
  /// 那三者的用户动作完全一样（重走一次授权），分开展示只会多三句废话。
  Future<AuthSession> siteLogin(String ticket);

  /// 撤销当前令牌。其他端的会话不受影响（C9）。
  Future<void> logout(String token);

  /// 注销账号（契约 `DELETE /api/me`）：匿名化保留、所有设备会话立刻失效。
  ///
  /// 与 [logout] 不同，**失败必须抛给调用方**——注销是用户明确表达的意图，
  /// 吞掉错误会让人以为账号已经注销。
  Future<void> deleteAccount(String token);

  /// 断开与网站的连接（`POST /api/auth/site-unlink`，无请求体）。
  ///
  /// 服务端会清身份映射并**撤销该账号全部会话（含当前这条）**，
  /// **账号与收藏/评论/浏览数据原样保留**；同一个站点身份重新授权会接回原账号。
  /// 成功后调用方必须清本地令牌，不要再打 `/me`（会 401）。
  Future<void> unlinkSite(String token);
}

/// 401 有两层含义，客户端必须按 `code` 区分：
/// - `INVALID_CREDENTIALS`：登录时账号密码不对，**不能清已有会话**；
/// - `UNAUTHORIZED`：令牌无效或过期，**应当清会话回登录页**。
const ApiException invalidCredentials = ApiException(
  code: ApiErrorCode.invalidCredentials,
  message: '账号或密码不正确',
  statusCode: 401,
);
