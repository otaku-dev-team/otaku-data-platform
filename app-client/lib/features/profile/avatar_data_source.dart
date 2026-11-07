import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/dio_client.dart';

/// 头像的上传 / 删除（`/api/me/account/avatar`）。
///
/// 与 `ProfileDataSource` 分开，因为**失败语义完全不同**：
///
/// - **2MB、jpg / png / webp**：服务端按**文件魔数**判断类型，不信任扩展名和
///   `Content-Type`。所以客户端不在这里预校验（猜也是猜），交给服务端 `400`
///   再把话传清楚；
/// - **1 分钟只能传 1 次**：超限 `429` + `Retry-After`。`ErrorInterceptor` 只
///   自动重试 `Retry-After <= 3s` 的 429，这里必然超过，所以会原样抛给调用方——
///   界面要说「N 秒后再试」，不能说「上传失败」（用户会立刻再点一次）；
/// - **删除幂等**：本来没头像也返回 `204`，不需要先查一次。
abstract interface class AvatarDataSource {
  /// 上传，返回服务端直出的新头像地址。
  Future<String> upload(String filePath);

  /// 删除（幂等）。
  Future<void> delete();
}

class HttpAvatarDataSource implements AvatarDataSource {
  const HttpAvatarDataSource(this._dio);

  final Dio _dio;

  static const String path = '/api/me/account/avatar';

  @override
  Future<String> upload(String filePath) async {
    // filename 只是给 multipart 一个名字：服务端按**魔数**判断真实类型，
    // 所以扩展名写错既不会被这里拦、也不会被服务端误收。
    final form = FormData.fromMap(<String, dynamic>{
      'file': await MultipartFile.fromFile(filePath),
    });
    final response = await _dio.post<Map<String, dynamic>>(path, data: form);

    final url = response.data?['avatar_url'];
    if (url is! String || url.isEmpty) {
      // 200 但没有地址 = 契约被破坏。当成功处理会让界面显示一个空头像，
      // 而且用户会以为已经换好了。
      throw const ApiException(
        code: ApiErrorCode.unknown,
        message: '服务端没有返回头像地址',
      );
    }
    return url;
  }

  @override
  Future<void> delete() => _dio.delete<void>(path);
}

/// 开发期实现（`USE_MOCK=true`，默认）。
///
/// **不假装上传成功**：返回一个坏地址会让界面显示纯色圆，用户以为「传上去了
/// 但没显示」，排查成本比直接报错高得多。这里明说「演示模式不上传」。
class MockAvatarDataSource implements AvatarDataSource {
  const MockAvatarDataSource();

  @override
  Future<String> upload(String filePath) async {
    throw const ApiException(
      code: ApiErrorCode.unknown,
      message: '演示模式（USE_MOCK=true）不上传头像，'
          '请用 --dart-define=USE_MOCK=false 联调',
    );
  }

  @override
  Future<void> delete() async {}
}

/// 换实现只改这一个 provider；测试用 `overrideWithValue` 注入假的。
final avatarDataSourceProvider = Provider<AvatarDataSource>((ref) {
  if (AppConfig.useMock) return const MockAvatarDataSource();
  return HttpAvatarDataSource(ref.watch(dioProvider));
});
