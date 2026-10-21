import 'package:dio/dio.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../models/collection_entry.dart';
import '../models/collection_state.dart';
import 'collection_data_source.dart';

/// 阶段 2 的真实收藏实现。契约见 `docs/openapi.yaml` 的 `/api/me/collections*`。
class RemoteCollectionDataSource implements CollectionDataSource {
  RemoteCollectionDataSource(this._dio);

  final Dio _dio;

  static const String _listPath = '/api/me/collections';
  static String _itemPath(String workId) =>
      '$_listPath/${Uri.encodeComponent(workId)}';

  /// 逐页取到最后一页。
  ///
  /// 契约支持分页，但收藏是「一个人的收藏」量级（几百条），一次取完比分页状态机简单得多。
  /// 真出现万条收藏再改滚动分页——那时要动的是 controller 和页面，这个方法签名不用变。
  /// 上限 [maxPages] 是防呆：万一 `total_pages` 返回异常，不至于在这里死循环。
  static const int maxPages = 100;

  @override
  Future<List<CollectionEntry>> fetchAll({CollectionStatus? status}) async {
    final items = <CollectionEntry>[];

    for (var page = 1; page <= maxPages; page++) {
      final response = await _call(
        () => _dio.get<Map<String, dynamic>>(
          _listPath,
          queryParameters: <String, dynamic>{
            // 省略表示全部；`none` 才是「已收藏但未设状态」。
            if (status != null) 'status': status.value,
            'page': page,
            'page_size': AppConfig.maxPageSize,
          },
        ),
      );

      final data = _body(response);
      final rawItems = data['items'];
      if (rawItems is! List) {
        throw const ApiException(
          code: ApiErrorCode.unknown,
          message: '收藏列表缺少 items',
        );
      }
      for (final raw in rawItems) {
        if (raw is! Map<String, dynamic>) {
          throw const FormatException('收藏列表项不是对象');
        }
        items.add(CollectionEntry.fromJson(raw));
      }

      final totalPages = data['total_pages'];
      if (totalPages is! int || page >= totalPages) break;
    }

    return List<CollectionEntry>.unmodifiable(items);
  }

  @override
  Future<CollectionState> fetchState(String workId) async {
    // 未收藏同样是 200 + collected:false，所以这里不需要吞 404。
    final response = await _call(
      () => _dio.get<Map<String, dynamic>>(_itemPath(workId)),
    );
    return CollectionState.fromJson(_body(response));
  }

  @override
  Future<CollectionState> add(String workId, {CollectionStatus? status}) async {
    // 必须是 PUT：契约里没有 POST，用 POST 会 405。
    // 省略 `status` 表示「收藏但不设状态」，upsert 语义下已有状态会被覆盖成 null。
    final response = await _call(
      () => _dio.put<Map<String, dynamic>>(
        _itemPath(workId),
        data: <String, dynamic>{if (status != null) 'status': status.value},
      ),
    );
    return CollectionState.fromJson(_body(response));
  }

  @override
  Future<CollectionState> updateStatus(
    String workId,
    CollectionStatus? status,
  ) async {
    // PATCH 只改不建：记录不存在时服务端返回 409 COLLECTION_REQUIRED，
    // 客户端**不得**收到 409 之后再补一个 PUT（那等于静默重新收藏，C11 直接失败）。
    // 显式传 null 表示「清除状态但保留收藏」。
    final response = await _call(
      () => _dio.patch<Map<String, dynamic>>(
        _itemPath(workId),
        data: <String, dynamic>{'status': status?.value},
      ),
    );
    return CollectionState.fromJson(_body(response));
  }

  @override
  Future<void> remove(String workId) async {
    // 幂等：本来就没收藏也返回 204，所以不需要先查一次。
    await _call(() => _dio.delete<void>(_itemPath(workId)));
  }

  static Map<String, dynamic> _body(Response<Map<String, dynamic>> response) {
    final data = response.data;
    if (data == null) {
      throw const ApiException(
        code: ApiErrorCode.unknown,
        message: '服务端返回了空响应',
      );
    }
    return data;
  }

  static Future<T> _call<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on DioException catch (error) {
      throw ApiException.fromDio(error);
    }
  }
}
