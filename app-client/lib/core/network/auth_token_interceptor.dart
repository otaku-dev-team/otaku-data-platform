import 'package:dio/dio.dart';

/// 自动给请求带上 `Authorization: Bearer <token>`。
///
/// 用路径白名单而不是「每个接口显式标记是否需要令牌」：需要鉴权的是多数，
/// 白名单只有两个，维护成本更低，也不会因为新增接口忘了标记而漏令牌。
///
/// 令牌读取出错（安全存储不可用）时**不阻断请求**，按未登录发出——
/// 服务端会返回 401，走统一的会话失效流程，比在这里抛一个界面上无法处理的异常好。
class AuthTokenInterceptor extends Interceptor {
  AuthTokenInterceptor(this._readToken);

  final Future<String?> Function() _readToken;

  /// 不带令牌的路径。
  ///
  /// `logout` 在契约里声明 `security: []`（令牌已失效也返回 204），带上过期令牌
  /// 反而让人以为它可能 401；`login` 更不该带旧会话。
  static const Set<String> _noAuthPaths = {
    '/api/auth/login',
    '/api/auth/logout',
  };

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (_noAuthPaths.contains(options.path)) {
      handler.next(options);
      return;
    }

    String? token;
    try {
      token = await _readToken();
    } on Object {
      token = null;
    }

    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }
}
