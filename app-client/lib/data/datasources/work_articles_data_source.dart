import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/dio_client.dart';
import '../models/article.dart';
import '../models/paged_result.dart';

/// #410 作品→资讯关联（消费 #409 的
/// `GET /api/works/{work_id}/articles`）。
///
/// **为什么不塞进 `ArticleDataSource`**：那三个方法（列表 / 详情 / 分类）被
/// 7 个测试里的假实现 `implements` 着，为 #410 加一个方法就要给每个不相关的
/// fake 补一段 stub。这是独立能力，单独一个接口，谁用谁注入。
///
/// ⚠️ 数据侧把 `related_work_ids` 从 content_id 切到 subject id 之前，
/// 服务端开关 `article.related_ids_semantic` 缺省关着，真接口**恒返回空**。
/// 空是有效结果，不是失败；区块整块不渲染即可，别显示空态。
abstract interface class WorkArticlesDataSource {
  Future<PagedResult<ArticleSummary>> fetch({
    required String workId,
    int page = 1,
    int pageSize = 20,
  });
}

class RemoteWorkArticlesDataSource implements WorkArticlesDataSource {
  RemoteWorkArticlesDataSource(this._dio);

  final Dio _dio;

  /// 路径挂在作品下面而不是 `/api/articles?work_id=`：后端按
  /// `work.source_id` 反查 `related_work_ids`，语义上是作品的子资源。
  static String _path(String workId) =>
      '/api/works/${Uri.encodeComponent(workId)}/articles';

  @override
  Future<PagedResult<ArticleSummary>> fetch({
    required String workId,
    int page = 1,
    int pageSize = 20,
  }) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        _path(workId),
        queryParameters: <String, dynamic>{
          'page': page,
          // 契约上限 50，超了服务端截断；这里只防呆。
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
      // 形状就是 ArticlePage：复用 ArticleSummary.fromJson，不新造模型。
      return PagedResult<ArticleSummary>.fromJson(data, ArticleSummary.fromJson);
    } on DioException catch (error) {
      throw ApiException.fromDio(error);
    }
  }
}

/// 开发期预览：给两条虚构资讯，让区块版式在真数据切流前也看得见。
///
/// 与真接口切流前的「恒空」**不等价**，这是刻意的：Mock 只服务版式，
/// 联调机上看到空区块才是线上预期。
class MockWorkArticlesDataSource implements WorkArticlesDataSource {
  const MockWorkArticlesDataSource();

  static const List<ArticleSummary> _sample = <ArticleSummary>[
    ArticleSummary(
      articleId: 'A-demo-001',
      title: '设定集发售纪念特辑',
      summary: '收录未公开的分镜与访谈。',
      category: '动画',
      sourceName: '首站',
    ),
    ArticleSummary(
      articleId: 'A-demo-002',
      title: '声优访谈：角色是怎么长出来的',
      category: '动画',
      sourceName: '首站',
    ),
  ];

  @override
  Future<PagedResult<ArticleSummary>> fetch({
    required String workId,
    int page = 1,
    int pageSize = 20,
  }) async {
    final size = pageSize.clamp(1, AppConfig.maxPageSize);
    final start = (page - 1) * size;
    final items = start >= _sample.length
        ? const <ArticleSummary>[]
        : _sample.sublist(
            start,
            start + size > _sample.length ? _sample.length : start + size,
          );
    return PagedResult<ArticleSummary>(
      items: items,
      total: _sample.length,
      page: page,
      pageSize: size,
      totalPages: 1,
    );
  }
}

/// 换实现只改这一个 provider。测试用 `overrideWithValue` 注入假数据源。
final workArticlesDataSourceProvider = Provider<WorkArticlesDataSource>((ref) {
  if (AppConfig.useMock) return const MockWorkArticlesDataSource();
  return RemoteWorkArticlesDataSource(ref.watch(dioProvider));
});

/// 作品详情页的区块数据。按 `workId` 建 family：不同作品各自缓存，
/// 返回上一页时不会拿错数据。
final workArticlesProvider =
    FutureProvider.family<PagedResult<ArticleSummary>, String>(
  (ref, workId) {
    return ref.watch(workArticlesDataSourceProvider).fetch(workId: workId);
  },
  // 关掉 Riverpod 3 的自动重试：失败态要显式呈现，不该变成转不完的骨架屏。
  retry: (retryCount, error) => null,
);
