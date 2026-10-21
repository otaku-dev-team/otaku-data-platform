import 'package:dio/dio.dart';

import '../../core/network/api_exception.dart';
import '../models/account_user.dart';
import 'auth_data_source.dart';

/// 阶段 2 的真实认证实现。契约见 `docs/openapi.yaml` 的 `/api/auth/*`。
class RemoteAuthDataSource implements AuthDataSource {
  RemoteAuthDataSource(this._dio);

  final Dio _dio;

  static const String _loginPath = '/api/auth/login';
  static const String _mePath = '/api/auth/me';
  static const String _logoutPath = '/api/auth/logout';

  @override
  Future<AuthSession> login({
    required String username,
    required String password,
  }) async {
    final response = await _call(
      () => _dio.post<Map<String, dynamic>>(
        _loginPath,
        data: <String, dynamic>{'username': username, 'password': password},
      ),
    );
    return AuthSession.fromJson(_body(response));
  }

  @override
  Future<AccountUser> me(String token) async {
    final response = await _call(
      () => _dio.get<Map<String, dynamic>>(
        _mePath,
        // 显式带令牌：冷启动恢复会话时内存缓存可能还没填好，
        // 这一条不能依赖拦截器。
        options: Options(headers: <String, dynamic>{'Authorization': 'Bearer $token'}),
      ),
    );
    return AccountUser.fromJson(_body(response));
  }

  @override
  Future<void> logout(String token) async {
    // 契约声明这个接口不需要鉴权（失效令牌也返回 204），但要撤销的是**当前这个**
    // 令牌，服务端正是靠这个头定位会话，所以仍然要带。
    await _call(
      () => _dio.post<void>(
        _logoutPath,
        options: Options(headers: <String, dynamic>{'Authorization': 'Bearer $token'}),
      ),
    );
  }

  static Map<String, dynamic> _body(Response<Map<String, dynamic>> response) {
    final data = response.data;
    if (data == null) {
      throw const ApiException(
        code: ApiErrorCode.unknown,
        message: '服务端返回了空响应',
      );
    }
    return data;
  }

  /// dio 异常统一换成 [ApiException]。
  ///
  /// 仓储层的 `restoreSession` 写的是 `on ApiException`，网络错误若以
  /// `DioException` 的形态穿透出去，那一段的「断网不清令牌」分支就永远进不去。
  static Future<T> _call<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on DioException catch (error) {
      throw ApiException.fromDio(error);
    }
  }
}
