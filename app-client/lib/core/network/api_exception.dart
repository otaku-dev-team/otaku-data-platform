import 'package:dio/dio.dart';

/// 契约第 7 节的错误码。接口②③④ 共用同一个信封：
/// `{"error": {"code": "...", "message": "..."}}`
enum ApiErrorCode {
  unauthorized('UNAUTHORIZED'),

  /// 登录时账号密码不对。与 [unauthorized] 同为 401，但**不能清已有会话**。
  invalidCredentials('INVALID_CREDENTIALS'),

  /// 改状态时该作品已不在收藏里（C11）。提示刷新，**不得静默重新收藏**。
  collectionRequired('COLLECTION_REQUIRED'),

  badRequest('BAD_REQUEST'),
  workNotFound('WORK_NOT_FOUND'),

  /// 资讯不存在。同样是 404，但「作品不存在」与「资讯不存在」提示不同，
  /// 混用一个码会让资讯详情页说出「作品不存在」。
  articleNotFound('ARTICLE_NOT_FOUND'),

  batchTooLarge('BATCH_TOO_LARGE'),
  rateLimited('RATE_LIMITED'),
  internal('INTERNAL'),

  /// 以下为客户端本地错误，不会出现在服务端响应里。
  network('NETWORK'),
  timeout('TIMEOUT'),
  cancelled('CANCELLED'),
  unknown('UNKNOWN');

  const ApiErrorCode(this.wireCode);

  final String wireCode;

  static ApiErrorCode fromWire(Object? raw) {
    for (final code in ApiErrorCode.values) {
      if (code.wireCode == raw) return code;
    }
    return ApiErrorCode.unknown;
  }
}

/// 客户端唯一的异常类型。dio 的原始异常在 [ErrorInterceptor] 里就转换掉，
/// 上层（仓储、页面）不需要认识 [DioException]。
class ApiException implements Exception {
  const ApiException({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final ApiErrorCode code;

  /// 服务端给的 message，或客户端本地的描述。可能为空。
  final String message;

  final int? statusCode;

  /// 契约 6.2：详情 404 只提示并返回列表，**不自动重试**。
  bool get isNotFound =>
      code == ApiErrorCode.workNotFound ||
      code == ApiErrorCode.articleNotFound;

  /// 「后端不可达」——网络断了、超时了这类**拿不到数据**的情况。
  ///
  /// 只有这一类错误才允许用离线缓存兜底。其余（404 / 400 / 401 / 429 / 500）
  /// 都是服务端的**明确答复**：服务端在说「这件事有结论」，
  /// 不是「我不知道」。拿缓存顶替等于替服务端编了一个结论出来——
  /// 把「作品不存在」说成「作品还在，只是没网」，方向正好和铁律 3
  /// 警告的「把失败当删除」相反，同样是错的。
  bool get isUnreachable =>
      code == ApiErrorCode.network || code == ApiErrorCode.timeout;

  /// 适合直接展示给用户的一句话。
  String get userMessage => switch (code) {
    ApiErrorCode.network => '网络连接失败，请检查网络后重试',
    ApiErrorCode.timeout => '请求超时，请稍后重试',
    ApiErrorCode.rateLimited => '请求太频繁了，请稍后再试',
    ApiErrorCode.internal => '服务端出错了，请稍后重试',
    ApiErrorCode.workNotFound => '作品不存在',
    ApiErrorCode.articleNotFound => '资讯不存在',
    ApiErrorCode.unauthorized => '登录已过期，请重新登录',
    ApiErrorCode.invalidCredentials => '账号或密码不正确',
    ApiErrorCode.collectionRequired => '该作品已不在收藏中，请刷新后重试',
    ApiErrorCode.cancelled => '请求已取消',
    _ => message.isNotEmpty ? message : '出了点问题，请重试',
  };

  /// 解析 `{"error": {"code": "...", "message": "..."}}`。
  /// 服务端还没按信封返回时（比如网关的 HTML 错误页）退化为按状态码推断。
  factory ApiException.fromResponse(Response<dynamic>? response) {
    final status = response?.statusCode;
    final body = response?.data;

    if (body is Map) {
      final envelope = body['error'];
      if (envelope is Map) {
        final rawMessage = envelope['message'];
        return ApiException(
          code: ApiErrorCode.fromWire(envelope['code']),
          message: rawMessage is String ? rawMessage : '',
          statusCode: status,
        );
      }
    }

    if (status == null) {
      return const ApiException(
        code: ApiErrorCode.unknown,
        message: '未知错误',
      );
    }
    return ApiException(
      code: switch (status) {
        401 => ApiErrorCode.unauthorized,
        404 => ApiErrorCode.workNotFound,
        429 => ApiErrorCode.rateLimited,
        >= 500 => ApiErrorCode.internal,
        _ => ApiErrorCode.unknown,
      },
      message: 'HTTP $status',
      statusCode: status,
    );
  }

  /// 已经是 [ApiException] 的直接返回（拦截器已经转过一次）。
  factory ApiException.fromDio(DioException error) {
    final wrapped = error.error;
    if (wrapped is ApiException) return wrapped;

    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => const ApiException(
        code: ApiErrorCode.timeout,
        message: '请求超时',
      ),
      DioExceptionType.connectionError => const ApiException(
        code: ApiErrorCode.network,
        message: '网络连接失败',
      ),
      DioExceptionType.cancel => const ApiException(
        code: ApiErrorCode.cancelled,
        message: '请求已取消',
      ),
      DioExceptionType.badCertificate => const ApiException(
        code: ApiErrorCode.network,
        message: '证书校验失败',
      ),
      _ => ApiException.fromResponse(error.response),
    };
  }

  /// 兜底转换。页面拿到的 `AsyncValue.error` 是 `Object?`，统一过这一道，
  /// 保证界面永远只处理 [ApiException] 一种错误。
  factory ApiException.fromAny(Object? error) {
    if (error is ApiException) return error;
    if (error is DioException) return ApiException.fromDio(error);
    return ApiException(
      code: ApiErrorCode.unknown,
      message: error?.toString() ?? '未知错误',
    );
  }

  @override
  String toString() => 'ApiException(${code.wireCode}, $statusCode): $message';
}
