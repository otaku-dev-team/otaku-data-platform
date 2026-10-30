import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import 'update_manifest.dart';

/// 拉取 `/downloads/latest.json`。
///
/// 单独用一个 Dio：API 那个 client 带认证拦截器，而更新清单是公开静态文件，
/// 不该把用户的 token 带到一个可能由 CDN/nginx 托管的地址上。
class UpdateService {
  UpdateService({Dio? dio, String? manifestUrl})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8),
            ),
          ),
      manifestUrl = manifestUrl ?? '${AppConfig.updateBaseUrl}/latest.json';

  final Dio _dio;
  final String manifestUrl;

  /// 拉清单。网络失败会抛 `DioException`，由调用方决定要不要提示；
  /// 清单结构不对返回 `null`（当成「没有更新」，这不是故障）。
  Future<UpdateManifest?> fetchLatest() async {
    final response = await _dio.get<Object?>(
      manifestUrl,
      // 清单必须每次拉到最新的：nginx / CDN 默认会缓存静态文件。
      queryParameters: {'t': DateTime.now().millisecondsSinceEpoch},
      options: Options(
        responseType: ResponseType.json,
        headers: const {'Cache-Control': 'no-cache'},
      ),
    );
    return UpdateManifest.tryParse(response.data);
  }
}

final updateServiceProvider = Provider<UpdateService>((ref) {
  return UpdateService();
});
