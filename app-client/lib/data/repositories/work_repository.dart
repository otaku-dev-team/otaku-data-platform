import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/dio_client.dart';
import '../../core/storage/work_cache.dart';
import '../../core/storage/work_cache_provider.dart';
import '../datasources/work_data_source.dart';
import '../datasources/work_mock_data_source.dart';
import '../datasources/work_remote_data_source.dart';
import '../models/paged_result.dart';
import '../models/related_works.dart';
import '../models/work.dart';
import '../models/work_sort.dart';
import '../models/work_summary.dart';
import '../models/work_type.dart';

/// 页面唯一的数据入口。它负责把底层异常收敛成 [ApiException]，
/// 页面不需要认识 dio，也不需要区分 Mock 与真接口。
class WorkRepository {
  WorkRepository(this._dataSource, {this._cache});

  final WorkDataSource _dataSource;

  /// 离线缓存。为 `null` 时不做缓存（Mock 模式就是这种情况）。
  final WorkCache? _cache;

  /// 列表。
  ///
  /// **在线优先，失败才回退缓存**：先打服务端，拿到就顺手写缓存。
  /// 只有「后端不可达」才用缓存兜底——明确 404 / 400 / 401 这些
  /// 是服务端的**明确答复**，不是「拿不到」。拿缓存顶上等于把
  /// 「作品不存在」说成「作品存在」，那和铁律 3 说的「把失败当删除」
  /// 是同一类错误，只是方向相反。
  Future<Fetched<PagedResult<WorkSummary>>> fetchWorks({
    WorkType? type,
    String? query,
    WorkSort sort = WorkSort.id,
    int page = 1,
    int pageSize = AppConfig.pageSize,
    String? tag,
    int? year,
  }) async {
    // 标签与年份都要进缓存键：**少一个维度就会取错内容**——「按科幻筛的第一页」
    // 与「不筛标签的第一页」共用一个键的话，离线时会拿到根本没筛过的内容，
    // 而界面上看不出任何异常（与 pageSize 同一个坑）。
    final key = ListCacheKey(
      type: type,
      query: query?.trim() ?? '',
      sort: sort,
      page: page,
      pageSize: pageSize,
      tag: tag,
      year: year,
    );

    try {
      final result = await _dataSource.fetchWorks(
        type: type,
        query: query,
        sort: sort,
        page: page,
        pageSize: pageSize,
        tag: tag,
        year: year,
      );
      await _cache?.writeList(
        key,
        CachedListPage(
          items: result.items,
          total: result.total,
          page: result.page,
          pageSize: result.pageSize,
          totalPages: result.totalPages,
        ),
      );
      return Fetched.live(result);
    } on ApiException catch (error) {
      if (!error.isUnreachable) rethrow;
      final cached = await _cache?.readList(key);
      if (cached == null) rethrow;
      return Fetched.cached(
        PagedResult<WorkSummary>(
          items: cached.value.items,
          // 分页元信息从缓存里取（缓存时一起存了），不拿 items 长度凑。
          total: cached.value.total,
          page: cached.value.page,
          pageSize: cached.value.pageSize,
          totalPages: cached.value.totalPages,
        ),
        cached.cachedAt,
      );
    } on DioException catch (error) {
      final converted = ApiException.fromDio(error);
      if (!converted.isUnreachable) throw converted;
      final cached = await _cache?.readList(key);
      if (cached == null) throw converted;
      return Fetched.cached(
        PagedResult<WorkSummary>(
          items: cached.value.items,
          total: cached.value.total,
          page: cached.value.page,
          pageSize: cached.value.pageSize,
          totalPages: cached.value.totalPages,
        ),
        cached.cachedAt,
      );
    } on FormatException catch (error) {
      throw ApiException(
        code: ApiErrorCode.unknown,
        message: '数据格式异常：${error.message}',
      );
    }
  }

  /// 详情。
  ///
  /// 回退规则同 [fetchWorks]。另外：**404 不回退**——
  /// 作品真的不存在时，界面该显示「作品不存在」并让用户返回列表，
  /// 而不是把一份可能已经过时的旧详情摆出来假装还在。
  Future<Fetched<Work>> fetchDetail(String workId) async {
    final key = DetailCacheKey(workId);
    try {
      final result = await _dataSource.fetchDetail(workId);
      await _cache?.writeDetail(key, result);
      return Fetched.live(result);
    } on ApiException catch (error) {
      if (!error.isUnreachable) rethrow;
      final cached = await _cache?.readDetail(key);
      if (cached == null) rethrow;
      return Fetched.cached(cached.value, cached.cachedAt);
    } on DioException catch (error) {
      final converted = ApiException.fromDio(error);
      if (!converted.isUnreachable) throw converted;
      final cached = await _cache?.readDetail(key);
      if (cached == null) throw converted;
      return Fetched.cached(cached.value, cached.cachedAt);
    } on FormatException catch (error) {
      throw ApiException(
        code: ApiErrorCode.unknown,
        message: '数据格式异常：${error.message}',
      );
    }
  }

  /// 同标签推荐。详情正文之外的补充，**失败不能连累详情**：
  /// 调用方（详情页）单独 catch，推荐区加载不出来时整块不渲染，
  /// 作品本身的信息照常显示。
  ///
  /// 推荐也走缓存：离线时详情页能顺带看到上次的相关推荐；
  /// 拿不到就不显示这一块——与在线时失败的处理一致。
  Future<Fetched<RelatedWorks>> fetchRelated(
    String workId, {
    int limit = 6,
  }) async {
    final key = RelatedCacheKey(workId);
    try {
      final result = await _dataSource.fetchRelated(workId, limit: limit);
      await _cache?.writeRelated(key, result);
      return Fetched.live(result);
    } on ApiException catch (error) {
      if (!error.isUnreachable) rethrow;
      final cached = await _cache?.readRelated(key);
      if (cached == null) rethrow;
      return Fetched.cached(cached.value, cached.cachedAt);
    } on DioException catch (error) {
      final converted = ApiException.fromDio(error);
      if (!converted.isUnreachable) throw converted;
      final cached = await _cache?.readRelated(key);
      if (cached == null) throw converted;
      return Fetched.cached(cached.value, cached.cachedAt);
    } on FormatException catch (error) {
      throw ApiException(
        code: ApiErrorCode.unknown,
        message: '数据格式异常：${error.message}',
      );
    }
  }
}

/// 一次取数的结果，外加「这数据是从哪来的」。
///
/// 为什么要带这个信息：离线回退时界面**必须**告诉用户看到的是缓存。
/// 不说的话，用户会以为自己在看最新的数据——那比直接报错更糟，
/// 因为它让人基于过期信息做判断（铁律 3）。
class Fetched<T> {
  const Fetched.live(this.value) : fromCache = false, cachedAt = null;

  const Fetched.cached(this.value, this.cachedAt) : fromCache = true;

  final T value;

  /// 这次的数据是不是来自本地缓存。
  final bool fromCache;

  /// 缓存写入时刻。只有 [fromCache] 为 true 时才有值。
  final DateTime? cachedAt;
}

/// 切换 Mock / 真接口的唯一开关。
final workDataSourceProvider = Provider<WorkDataSource>((ref) {
  if (AppConfig.useMock) {
    return MockWorkDataSource();
  }
  return RemoteWorkDataSource(ref.watch(dioProvider));
});

final workRepositoryProvider = Provider<WorkRepository>((ref) {
  return WorkRepository(
    ref.watch(workDataSourceProvider),
    // Mock 模式不接缓存：Mock 数据本来就是本地的，再存一份没有意义，
    // 还会让测试里出现「缓存命中」这种意料之外的状态。
    cache: AppConfig.useMock ? null : ref.watch(workCacheProvider),
  );
});
