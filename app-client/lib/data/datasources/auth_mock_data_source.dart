import '../../core/network/api_exception.dart';
import '../models/account_user.dart';
import 'auth_data_source.dart';

/// 开发 / 联调期的假认证源（`USE_MOCK=true` 时默认走它，真接口见 auth_remote_data_source.dart）。
///
/// 只用来把登录流程、令牌持久化、退出登录的界面跑通，**不代表最终接口语义**：
/// - 任意非空用户名 + 非空密码都能登录；密码是 `wrong` 时返回 401 `INVALID_CREDENTIALS`；
/// - 令牌形如 `mock-token-<username>`，`me()` 从令牌里还原用户名，
///   这样重启后仍能验证「令牌被真的存下来了」。
class AuthMockDataSource implements AuthDataSource {
  AuthMockDataSource({this.delay = const Duration(milliseconds: 400)});

  final Duration delay;

  static const String _tokenPrefix = 'mock-token-';

  /// 已用过的票据（模拟站点侧的「一次性」）。
  ///
  /// 实例字段而不是顶层静态：测试之间不该互相看见对方的票据，
  /// 否则「重放必须失败」这条断言会因用例顺序而时红时绿。
  final Set<String> _usedTickets = <String>{};

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

  /// 站点授权登录的假实现。
  ///
  /// 五条可驱动的分支，对应真实链路上最常见的失败：
  /// - ticket 为空 → 400（回调构造不完整）；
  /// - ticket 是 `expired` → 401 `INVALID_CREDENTIALS`（票据超时或被用过，
  ///   平台后端归一后都是这个码，**实测确认**，不是猜的）；
  /// - ticket 是 `disabled` → 403 `USER_DISABLED`（映射的平台账号被禁用）；
  /// - ticket 是 `site-down` → 503 `SITE_UNAVAILABLE`（站点侧不可用）；
  /// - 其他 → 成功，返回一个**站点身份**的账号（`identity_source` 有值），
  ///   这样桌面走查能看到「账号菜单显示身份来源」这一支。
  ///
  /// 票据一次性也模拟了：同一个 ticket 第二次用会 401——真实链路里这是
  /// 站点侧的行为，客户端表现（重走授权）完全一致。
  @override
  Future<AuthSession> siteLogin(String ticket) async {
    await Future<void>.delayed(delay);

    final normalized = ticket.trim();
    if (normalized.isEmpty) {
      throw const ApiException(
        code: ApiErrorCode.badRequest,
        message: '授权没有返回票据',
        statusCode: 400,
      );
    }
    if (normalized == 'expired' || _usedTickets.contains(normalized)) {
      // ⚠️ 码必须是**后端实际返的那个**：2026-10-29 对生产实测，假票据返
      // `401 INVALID_CREDENTIALS`。早先这里写的是 `UNAUTHORIZED`，于是
      // `AuthController._siteLoginError` 那条分支在 mock 下命中、真机上不命中
      // ——测试全绿而真机错文案（显示成「账号或密码不正确」）。
      throw const ApiException(
        code: ApiErrorCode.invalidCredentials,
        message: '站点授权已失效，请重新登录',
        statusCode: 401,
      );
    }
    if (normalized == 'disabled') {
      throw const ApiException(
        code: ApiErrorCode.userDisabled,
        message: '账号已被禁用',
        statusCode: 403,
      );
    }
    if (normalized == 'site-down') {
      throw const ApiException(
        code: ApiErrorCode.siteUnavailable,
        message: '站点登录暂不可用，请稍后再试',
        statusCode: 503,
      );
    }
    _usedTickets.add(normalized);

    return AuthSession(
      token: '$_tokenPrefix${'site-'}${normalized.substring(0, normalized.length > 8 ? 8 : normalized.length)}',
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 30)),
      user: AccountUser(
        userId: 'mock-site-user-$normalized',
        username: 'otaku_$normalized',
        displayName: '站点用户',
        identitySource: 'otaku_site',
      ),
    );
  }
}
