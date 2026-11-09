import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/dio_client.dart';
import '../../data/models/work_summary.dart';
import '../../data/models/work_type.dart';

/// 首页 hero 海报候选（`GET /api/home/posters`，#561 / #562）。
///
/// 最多 12 条，顺序即展示顺序。**空数组不是错误**：当季还没有「取得到封面」
/// 的动画时返回 0 条，客户端隐藏整块 hero，不填假数据、不留白。
abstract interface class HomePosterDataSource {
  Future<List<WorkSummary>> fetch();
}

class HomePosterRemoteDataSource implements HomePosterDataSource {
  const HomePosterRemoteDataSource(this._dio);

  final Dio _dio;

  static const String path = '/api/home/posters';

  @override
  Future<List<WorkSummary>> fetch() async {
    final response = await _dio.get<Map<String, dynamic>>(path);
    final data = response.data;
    if (data == null) {
      throw const ApiException(
        code: ApiErrorCode.unknown,
        message: '服务端返回了空响应',
      );
    }
    final raw = data['items'];
    if (raw is! List) return const <WorkSummary>[];
    final items = <WorkSummary>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      try {
        items.add(WorkSummary.fromJson(Map<String, dynamic>.from(entry)));
      } on FormatException {
        // 单条坏卡跳过：hero 少一张比整块消失好。
        continue;
      }
    }
    return List<WorkSummary>.unmodifiable(items);
  }
}

/// 开发期实现：5 张虚构海报，够看出 Coverflow 的形状。
class HomePosterMockDataSource implements HomePosterDataSource {
  const HomePosterMockDataSource();

  @override
  Future<List<WorkSummary>> fetch() async => const <WorkSummary>[
    WorkSummary(
      workId: 'poster-1',
      workType: WorkType.anime,
      title: '银河边缘的旧书店',
      releaseYear: 2024,
      source: 'shell',
    ),
    WorkSummary(
      workId: 'poster-2',
      workType: WorkType.anime,
      title: '雨夜考据部',
      releaseYear: 2023,
      source: 'shell',
    ),
    WorkSummary(
      workId: 'poster-3',
      workType: WorkType.anime,
      title: '机战少女的黄昏',
      releaseYear: 2025,
      source: 'shell',
    ),
    WorkSummary(
      workId: 'poster-4',
      workType: WorkType.anime,
      title: '夏日回声',
      releaseYear: 2022,
      source: 'shell',
    ),
    WorkSummary(
      workId: 'poster-5',
      workType: WorkType.anime,
      title: '不眠之城',
      releaseYear: 2026,
      source: 'shell',
    ),
  ];
}

final homePosterDataSourceProvider = Provider<HomePosterDataSource>((ref) {
  if (AppConfig.useMock) return const HomePosterMockDataSource();
  return HomePosterRemoteDataSource(ref.watch(dioProvider));
});

/// 首页海报。失败返回空列表而不是抛：hero 是装饰位，不该让整页变错误态。
final homePostersProvider = FutureProvider<List<WorkSummary>>((ref) async {
  try {
    return await ref.watch(homePosterDataSourceProvider).fetch();
  } catch (_) {
    return const <WorkSummary>[];
  }
}, retry: (retryCount, error) => null);
