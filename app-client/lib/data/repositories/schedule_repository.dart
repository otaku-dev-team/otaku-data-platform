import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/dio_client.dart';
import '../datasources/schedule_data_source.dart';
import '../datasources/schedule_mock_data_source.dart';
import '../datasources/schedule_remote_data_source.dart';
import '../models/schedule.dart';

/// 档期仓储。与作品/收藏同一模式：页面不认识 dio，也不区分 Mock 与真接口。
class ScheduleRepository {
  ScheduleRepository(this._dataSource);

  final ScheduleDataSource _dataSource;

  Future<SchedulePageData> fetchSchedule({String? season}) async {
    try {
      return await _dataSource.fetchSchedule(season: season);
    } on ApiException {
      rethrow;
    } on DioException catch (error) {
      throw ApiException.fromDio(error);
    } on FormatException catch (error) {
      throw ApiException(
        code: ApiErrorCode.unknown,
        message: '数据格式异常：${error.message}',
      );
    }
  }
}

final scheduleDataSourceProvider = Provider<ScheduleDataSource>((ref) {
  if (AppConfig.useMock) {
    return const MockScheduleDataSource();
  }
  return RemoteScheduleDataSource(ref.watch(dioProvider));
});

final scheduleRepositoryProvider = Provider<ScheduleRepository>((ref) {
  return ScheduleRepository(ref.watch(scheduleDataSourceProvider));
});
