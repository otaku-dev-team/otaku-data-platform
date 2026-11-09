import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/dio_client.dart';
import '../../data/models/work_summary.dart';
import '../../data/models/work_type.dart';

/// 冷启动题面（#492 / #505）。`works` 就是列表里那种作品卡，客户端不用为漏斗
/// 另学一套字段。
class QuizPaper {
  const QuizPaper({
    required this.seed,
    required this.size,
    required this.works,
  });

  /// 「换一批」= 这个值 + 1。**用返回值**，不要用自己传进去的
  /// （超过 10^6 会被服务端取模）。
  final int seed;

  /// **实际**题量，等于 `works.length`。候选不够时会小于请求值，
  /// 进度条必须按它算，否则永远差最后一格。
  final int size;

  final List<WorkSummary> works;
}

/// 题面来源。匿名可读——题面只是公开作品卡片，不含个人数据；
/// **写答案才鉴权**（走 `PUT /api/me/collections/{id}`）。
abstract interface class PersonaQuizDataSource {
  Future<QuizPaper> fetchPaper({required int seed, required int size});
}

class PersonaQuizRemoteDataSource implements PersonaQuizDataSource {
  const PersonaQuizRemoteDataSource(this._dio);

  final Dio _dio;

  static const String path = '/api/persona/quiz';

  @override
  Future<QuizPaper> fetchPaper({required int seed, required int size}) async {
    final response = await _dio.get<Map<String, dynamic>>(
      path,
      queryParameters: <String, dynamic>{'seed': seed, 'size': size},
    );
    final data = response.data;
    if (data == null) {
      throw const ApiException(
        code: ApiErrorCode.unknown,
        message: '服务端返回了空响应',
      );
    }

    final rawWorks = data['works'];
    final works = <WorkSummary>[];
    if (rawWorks is List) {
      for (final raw in rawWorks) {
        if (raw is! Map) continue;
        try {
          works.add(WorkSummary.fromJson(Map<String, dynamic>.from(raw)));
        } on FormatException {
          // 单条坏卡不能毁掉整份题面：少一道题比「加载失败」好。
          continue;
        }
      }
    }

    return QuizPaper(
      seed: _int(data['seed']),
      // ⚠️ 按**解析出来的条数**算，不直接信服务端的 `size`。
      //
      // 契约要求 `size == works.length`，但上面会跳过坏卡：一旦跳过，
      // 服务端仍是 20、这里只有 19，页面按 20 判断「还没做完」，
      // 翻到第 20 张时 `works[19]` 直接越界崩。进度条也因此会差最后一格。
      size: works.length,
      works: List<WorkSummary>.unmodifiable(works),
    );
  }

  static int _int(Object? raw, {int fallback = 0}) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? fallback;
    return fallback;
  }
}

/// 开发期实现：造一份固定题面，不连后端也能把交互走完。
class PersonaQuizMockDataSource implements PersonaQuizDataSource {
  const PersonaQuizMockDataSource();

  static const List<String> _titles = <String>[
    '银河边缘的旧书店',
    '雨夜考据部',
    '机战少女的黄昏',
    '夏日回声',
    '黑猫与旧唱片',
    '第七号档案',
    '海边的天文台',
    '不眠之城',
    '纸飞机协定',
    '深空邮差',
  ];

  @override
  Future<QuizPaper> fetchPaper({required int seed, required int size}) async {
    final works = <WorkSummary>[
      for (var i = 0; i < size; i++)
        WorkSummary(
          workId: 'quiz-$i',
          workType: WorkType.anime,
          title: '${_titles[i % _titles.length]} ${i + 1}',
          releaseYear: 2008 + (i % 17),
          tags: const <List<String>>[
            <String>['科幻', '群像'],
            <String>['日常', '治愈'],
            <String>['悬疑', '群像'],
          ][i % 3],
          source: 'shell',
        ),
    ];
    return QuizPaper(seed: seed, size: works.length, works: works);
  }
}

/// 切实现只改这里：`USE_MOCK=false` 时走真接口。
final personaQuizDataSourceProvider = Provider<PersonaQuizDataSource>((ref) {
  if (AppConfig.useMock) return const PersonaQuizMockDataSource();
  return PersonaQuizRemoteDataSource(ref.watch(dioProvider));
});

/// 题面。key 是 `(seed, size)`——同 seed 同题面，换一批用 `seed + 1`。
final personaQuizPaperProvider =
    FutureProvider.family<QuizPaper, ({int seed, int size})>((ref, key) {
      return ref.watch(personaQuizDataSourceProvider).fetchPaper(
        seed: key.seed,
        size: key.size,
      );
      // 契约要求失败显式呈现：自动重试会让失败看起来像一直在加载。
    }, retry: (retryCount, error) => null);
