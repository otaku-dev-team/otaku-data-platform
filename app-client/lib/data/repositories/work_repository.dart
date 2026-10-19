import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/dio_client.dart';
import '../datasources/work_data_source.dart';
import '../datasources/work_mock_data_source.dart';
import '../datasources/work_remote_data_source.dart';
import '../models/paged_result.dart';
import '../models/work.dart';
import '../models/work_summary.dart';
import '../models/work_type.dart';

/// 页面唯一的数据入口。它负责把底层异常收敛成 [ApiException]，
/// 页面不需要认识 dio，也不需要区分 Mock 与真接口。
class WorkRepository {
  WorkRepository(this._dataSource);

  final WorkDataSource _dataSource;

  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    int page = 1,
    int pageSize = AppConfig.pageSize,
  }) async {
    try {
      return await _dataSource.fetchWorks(
        type: type,
        query: query,
        page: page,
        pageSize: pageSize,
      );
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

  Future<Work> fetchDetail(String workId) async {
    try {
      return await _dataSource.fetchDetail(workId);
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

/// 切换 Mock / 真接口的唯一开关。
final workDataSourceProvider = Provider<WorkDataSource>((ref) {
  if (AppConfig.useMock) {
    return MockWorkDataSource();
  }
  return RemoteWorkDataSource(ref.watch(dioProvider));
});

final workRepositoryProvider = Provider<WorkRepository>((ref) {
  return WorkRepository(ref.watch(workDataSourceProvider));
});
