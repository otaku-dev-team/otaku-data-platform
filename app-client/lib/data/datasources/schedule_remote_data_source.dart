import 'package:dio/dio.dart';

import '../../core/network/api_exception.dart';
import '../models/schedule.dart';
import 'schedule_data_source.dart';

/// 真实接口实现。契约：`GET /api/schedule?season=`。
///
/// 不传分页参数：后端按星期分组一次返回（一个季度几百条），
/// 分页只会让「看完整一周」变成 7 次请求。
class RemoteScheduleDataSource implements ScheduleDataSource {
  RemoteScheduleDataSource(this._dio);

  final Dio _dio;

  static const String _path = '/api/schedule';

  @override
  Future<SchedulePageData> fetchSchedule({String? season}) async {
    final response = await _dio.get<Map<String, dynamic>>(
      _path,
      queryParameters: <String, dynamic>{
        if (season != null && season.isNotEmpty) 'season': season,
      },
    );

    final data = response.data;
    if (data == null) {
      throw const ApiException(
        code: ApiErrorCode.unknown,
        message: '服务端返回了空响应',
      );
    }
    return SchedulePageData.fromJson(data);
  }
}
