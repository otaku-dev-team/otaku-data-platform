import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/dio_client.dart';
import '../../data/models/series_page.dart';
import '../../data/models/work_series.dart';
import '../../data/models/work_summary.dart';

/// 系列相关两个端点的入口（#557）。
///
/// **单独一个数据源，没有挂到 `WorkDataSource` 上**：系列是独立功能，
/// 塞进作品数据源会让所有测试里的假实现都被迫实现两个无关方法
/// （公司页 #558 实测一次改动波及 29 个假实现）。功能边界 = 数据源边界。
abstract interface class SeriesDataSource {
  /// 系列目录页：`GET /api/series/{key}`，按评分排、可分页。
  Future<SeriesPage> fetchPage(String key, {int limit = 60, int offset = 0});

  /// 详情页系列区：`GET /api/works/{work_id}/series`，按年代排、带关系标签。
  Future<WorkSeries> fetchForWork(String workId);
}

class SeriesRemoteDataSource implements SeriesDataSource {
  const SeriesRemoteDataSource(this._dio);

  final Dio _dio;

  static const String _pagePath = '/api/series';

  /// 系列键是**不透明字符串**：整值编码后当路径段，不解析、不截断。
  static String pagePathOf(String key) => '$_pagePath/${Uri.encodeComponent(key)}';

  /// `work_id` 同样是不透明字符串（v3 后带前缀键），整值编码。
  static String workSeriesPathOf(String workId) =>
      '/api/works/${Uri.encodeComponent(workId)}/series';

  @override
  Future<SeriesPage> fetchPage(
    String key, {
    int limit = 60,
    int offset = 0,
  }) async {
    final response = await _dio.get<Map<String, dynamic>>(
      pagePathOf(key),
      queryParameters: <String, dynamic>{
        'limit': limit.clamp(1, 200),
        'offset': offset < 0 ? 0 : offset,
      },
    );
    return SeriesPage.fromJson(_body(response.data));
  }

  @override
  Future<WorkSeries> fetchForWork(String workId) async {
    final response = await _dio.get<Map<String, dynamic>>(
      workSeriesPathOf(workId),
    );
    return WorkSeries.fromJson(_body(response.data));
  }

  Map<String, dynamic> _body(Map<String, dynamic>? data) {
    if (data == null) {
      throw const ApiException(
        code: ApiErrorCode.unknown,
        message: '服务端返回了空响应',
      );
    }
    return data;
  }
}

/// 开发期实现：mock 资产里没有系列字段，所以两个入口都给「没有系列」。
/// 系列区会整块隐藏，系列页给空态——都是数据事实的诚实表达，不编假系列。
class SeriesMockDataSource implements SeriesDataSource {
  const SeriesMockDataSource();

  @override
  Future<SeriesPage> fetchPage(
    String key, {
    int limit = 60,
    int offset = 0,
  }) async {
    return SeriesPage(key: key, total: 0, items: const <WorkSummary>[]);
  }

  @override
  Future<WorkSeries> fetchForWork(String workId) async {
    return const WorkSeries(items: <WorkSeriesItem>[]);
  }
}

/// 切实现只改这里：`USE_MOCK=false` 时走真接口。
final seriesDataSourceProvider = Provider<SeriesDataSource>((ref) {
  if (AppConfig.useMock) return const SeriesMockDataSource();
  return SeriesRemoteDataSource(ref.watch(dioProvider));
});
