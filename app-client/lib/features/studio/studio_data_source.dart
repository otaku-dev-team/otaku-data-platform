import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/dio_client.dart';
import '../../data/models/studio_page.dart';
import '../../data/models/work_summary.dart';
import '../../data/models/work_type.dart';

/// 制作公司页的数据入口（`GET /api/studios/{name}`，#557）。
///
/// **单独一个数据源，没有挂到 `WorkDataSource` 上**：公司页是独立功能，
/// 塞进作品数据源会让所有测试里的假实现都被迫实现一个跟它们无关的方法
/// （实测一次改动波及 29 个假实现）。功能边界就该是数据源边界。
abstract interface class StudioDataSource {
  Future<StudioPage> fetch(String name, {int limit = 60, int offset = 0});
}

class StudioRemoteDataSource implements StudioDataSource {
  const StudioRemoteDataSource(this._dio);

  final Dio _dio;

  static const String basePath = '/api/studios';

  /// 公司名整值编码后当路径段。**不要 lowercase / trim / 归一**：
  /// 服务端按二进制排序规则精确匹配，客户端擅自归一反而会打到另一家公司。
  static String pathOf(String name) =>
      '$basePath/${Uri.encodeComponent(name)}';

  @override
  Future<StudioPage> fetch(
    String name, {
    int limit = 60,
    int offset = 0,
  }) async {
    final response = await _dio.get<Map<String, dynamic>>(
      pathOf(name),
      queryParameters: <String, dynamic>{
        'limit': limit.clamp(1, 200),
        'offset': offset < 0 ? 0 : offset,
      },
    );
    final data = response.data;
    if (data == null) {
      throw const ApiException(
        code: ApiErrorCode.unknown,
        message: '服务端返回了空响应',
      );
    }
    return StudioPage.fromJson(data);
  }
}

/// 开发期实现：给一批固定作品，只为看版式。
///
/// 真数据里公司关系是 `work_studios` 的 4,269 行，mock 资产里没有这个字段，
/// 所以这里不假装能按公司筛。
class StudioMockDataSource implements StudioDataSource {
  const StudioMockDataSource();

  @override
  Future<StudioPage> fetch(
    String name, {
    int limit = 60,
    int offset = 0,
  }) async {
    final all = <WorkSummary>[
      for (var i = 0; i < 6; i++)
        WorkSummary(
          workId: 'studio-$i',
          workType: WorkType.anime,
          title: '$name的作品 ${i + 1}',
          releaseYear: 2015 + i,
          tags: const <String>['科幻', '群像'],
          source: 'shell',
        ),
    ];
    final items = all.skip(offset).take(limit).toList(growable: false);
    return StudioPage(name: name, total: all.length, items: items);
  }
}

/// 切实现只改这里：`USE_MOCK=false` 时走真接口。
final studioDataSourceProvider = Provider<StudioDataSource>((ref) {
  if (AppConfig.useMock) return const StudioMockDataSource();
  return StudioRemoteDataSource(ref.watch(dioProvider));
});
