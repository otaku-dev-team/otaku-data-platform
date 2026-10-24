import 'package:dio/dio.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../models/paged_result.dart';
import '../models/related_works.dart';
import '../models/work.dart';
import '../models/work_sort.dart';
import '../models/work_summary.dart';
import '../models/work_type.dart';
import 'work_data_source.dart';

/// 真实接口实现。契约 6.1 / 6.2，路径以 Java 最终定义为准，
/// 若 Java 换了路径，只改这两个常量。
class RemoteWorkDataSource implements WorkDataSource {
  RemoteWorkDataSource(this._dio);

  final Dio _dio;

  static const String _listPath = '/api/works';
  static String _detailPath(String workId) =>
      '/api/works/${Uri.encodeComponent(workId)}';
  static String _relatedPath(String workId) =>
      '/api/works/${Uri.encodeComponent(workId)}/related';

  @override
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    WorkSort sort = WorkSort.id,
    int page = 1,
    int pageSize = AppConfig.pageSize,
    String? tag,
  }) async {
    final keyword = query?.trim() ?? '';
    final response = await _dio.get<Map<String, dynamic>>(
      _listPath,
      queryParameters: <String, dynamic>{
        if (type != null && type != WorkType.unknown) 'type': type.value,
        if (keyword.isNotEmpty) 'q': keyword,
        // 标签精确匹配整个标签。空值不带这个参数——服务端把省略与空串都当不过滤。
        if (tag != null && tag.trim().isNotEmpty) 'tag': tag.trim(),
        // 契约：省略等价于 id，非法取值服务端返回 400。
        // 默认项也显式带上，好处是抓包时能一眼看出这一页用的是哪种顺序。
        'sort': sort.value,
        'page': page,
        // 契约：上限 50，超了服务端截断，客户端不必自己裁剪；这里只防呆。
        'page_size': pageSize.clamp(1, AppConfig.maxPageSize),
      },
    );

    final data = response.data;
    if (data == null) {
      throw const ApiException(
        code: ApiErrorCode.unknown,
        message: '服务端返回了空响应',
      );
    }
    return PagedResult<WorkSummary>.fromJson(data, WorkSummary.fromJson);
  }

  @override
  Future<Work> fetchDetail(String workId) async {
    final response = await _dio.get<Map<String, dynamic>>(
      _detailPath(workId),
    );

    final data = response.data;
    if (data == null) {
      throw const ApiException(
        code: ApiErrorCode.unknown,
        message: '服务端返回了空响应',
      );
    }
    return Work.fromJson(data);
  }

  @override
  Future<RelatedWorks> fetchRelated(String workId, {int limit = 6}) async {
    final response = await _dio.get<Map<String, dynamic>>(
      _relatedPath(workId),
      queryParameters: <String, dynamic>{
        // 契约：省略为 6，超过 20 服务端按 20 截断，这里只防呆。
        'limit': limit.clamp(1, 20),
      },
    );

    final data = response.data;
    if (data == null) {
      throw const ApiException(
        code: ApiErrorCode.unknown,
        message: '服务端返回了空响应',
      );
    }
    return RelatedWorks.fromJson(data);
  }
}
