import 'package:dio/dio.dart';

import '../../core/network/api_exception.dart';
import '../models/tag_vocabulary.dart';
import '../models/work_type.dart';
import 'tag_data_source.dart';

/// 真接口：`GET /api/tags`。
class RemoteTagDataSource implements TagDataSource {
  RemoteTagDataSource(this._dio);

  final Dio _dio;

  static const String _path = '/api/tags';

  @override
  Future<TagVocabulary> fetchTags({WorkType? type, int? limit}) async {
    final response = await _dio.get<Map<String, dynamic>>(
      _path,
      queryParameters: <String, dynamic>{
        if (type != null && type != WorkType.unknown) 'type': type.value,
        // 契约：上限 2000，超过按 2000 截断不报错；这里只防呆，不越权替服务端裁剪。
        if (limit != null) 'limit': limit.clamp(1, 2000),
      },
    );

    final data = response.data;
    if (data == null) {
      throw const ApiException(
        code: ApiErrorCode.unknown,
        message: '服务端返回了空响应',
      );
    }
    return TagVocabulary.fromJson(data);
  }
}
