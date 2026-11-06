import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/dio_client.dart';
import '../../data/models/work_summary.dart';
import '../../data/models/work_type.dart';
import '../auth/auth_controller.dart';
import 'persona_insight_mapper.dart';
import 'persona_mock_data.dart';
import 'persona_view_data.dart';

/// 画像 / 个性化推荐的**唯一数据入口**。
///
/// 2026-11-07：`GET /api/me/profile`（#401）与 `GET /api/me/recommend`（#402）
/// 均已上线，**两个都接了真数据**：
///
/// - #376 推荐位：[PersonaRemoteDataSource.fetchFeed] 消费 `/api/me/recommend`；
/// - #375 画像页：[PersonaRemoteDataSource.fetchInsight] 消费 `/api/me/profile`，
///   六轴由 [PersonaInsightMapper] 按固定公式派生（口径见
///   `docs/persona-mapping-proposal.md` §3A）。
///
/// 换实现只改 [personaDataSourceProvider]；测试用 `overrideWithValue` 注入假数据源。
abstract interface class PersonaDataSource {
  Future<PersonaInsight> fetchInsight();

  /// [signedIn] 由页面层传入：游客不请求个性化接口（#376 回落默认榜）。
  Future<PersonaFeed> fetchFeed({required bool signedIn});
}

/// 开发期演示数据。`USE_MOCK=true`（默认）时使用。
class PersonaMockDataSource implements PersonaDataSource {
  const PersonaMockDataSource();

  @override
  Future<PersonaInsight> fetchInsight() async => kShellPersonaInsight;

  @override
  Future<PersonaFeed> fetchFeed({required bool signedIn}) async {
    return PersonaFeed(
      isGuest: !signedIn,
      items: signedIn ? kShellRecommendations : const <RecommendedWork>[],
    );
  }
}

/// #376 真数据源：`GET /api/me/recommend`（契约 `RecommendationPage`）。
///
/// 规则 key → 理由文案、条目容错都收在这里，页面层只认展示模型。
class PersonaRemoteDataSource implements PersonaDataSource {
  const PersonaRemoteDataSource(this._dio);

  final Dio _dio;

  static const String recommendPath = '/api/me/recommend';

  static const String profilePath = '/api/me/profile';

  /// 首页横排用 20 条：契约默认 20、上限 50，取默认值即可。
  static const int _limit = 20;

  /// #375 画像页：把 `PersonaProfile` 的权重映射成展示模型。
  ///
  /// ⚠️ 这不等于「服务端算了六维」——服务端只给类型 / 标签权重与评分倾向，
  /// 六根轴是**客户端按固定公式派生**的（[PersonaInsightMapper]，口径见
  /// `docs/persona-mapping-proposal.md` §3A）。
  ///
  /// 代价是轴名与早期设计稿不同：设计稿的「热度」「社交」没有数据源
  /// （前者要全站基准，后者要拆分的点评条数），已经放弃，换成能追溯来源的六轴。
  @override
  Future<PersonaInsight> fetchInsight() async {
    final response = await _dio.get<Map<String, dynamic>>(profilePath);
    final data = response.data;
    if (data == null) {
      throw const ApiException(
        code: ApiErrorCode.unknown,
        message: '服务端返回了空响应',
      );
    }
    return PersonaInsightMapper.fromProfile(data);
  }

  @override
  Future<PersonaFeed> fetchFeed({required bool signedIn}) async {
    if (!signedIn) {
      // 接口要求登录。游客硬打会拿 401，而 dio 的 401 拦截器会广播
      // 「会话已过期」——等于翻个首页把登录态踢掉。
      return const PersonaFeed(isGuest: true);
    }

    final response = await _dio.get<Map<String, dynamic>>(
      recommendPath,
      queryParameters: <String, dynamic>{'limit': _limit},
    );
    final data = response.data;
    if (data == null) {
      throw const ApiException(
        code: ApiErrorCode.unknown,
        message: '服务端返回了空响应',
      );
    }

    final items = <RecommendedWork>[];
    final rawItems = data['items'];
    if (rawItems is List) {
      for (final raw in rawItems) {
        if (raw is! Map) continue;
        final work = raw['work'];
        if (work is! Map) continue;
        try {
          items.add(
            RecommendedWork(
              work: WorkSummary.fromJson(Map<String, dynamic>.from(work)),
              reasons: _reasons(raw['reasons']),
            ),
          );
        } on FormatException {
          // 单条坏数据不该让整块推荐消失：推荐位是列表，不是数据一致性场景。
          continue;
        }
      }
    }

    return PersonaFeed(
      isGuest: false,
      items: List<RecommendedWork>.unmodifiable(items),
      coldStart: data['cold_start'] == true,
    );
  }

  /// `RecommendationReason` → 人话。
  ///
  /// - `type=tag` / `type=type`，`value` 分别是标签名与四值类型；
  /// - `weight <= 0` 是「不喜欢」的证据，绝不能当成推荐理由显示出来；
  /// - 未知 `type` 不猜文案，直接丢掉；契约上限 3 条，这里再兜一道。
  static List<String> _reasons(Object? raw) {
    if (raw is! List) return const <String>[];
    final result = <String>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final weight = entry['weight'];
      if (weight is! num || weight <= 0) continue;
      final value = entry['value'];
      if (value is! String || value.trim().isEmpty) continue;
      final label = value.trim();
      String? text;
      final type = entry['type'];
      if (type == 'tag') {
        text = '你偏爱的「$label」';
      } else if (type == 'type') {
        final workType = WorkType.fromValue(label);
        text = workType == WorkType.unknown ? null : '你常看的${workType.label}';
      }
      if (text != null) result.add(text);
    }
    return List<String>.unmodifiable(result.take(3));
  }
}

/// 换实现只改这一个 provider。测试用 `overrideWithValue` 注入假数据源。
final personaDataSourceProvider = Provider<PersonaDataSource>((ref) {
  if (AppConfig.useMock) return const PersonaMockDataSource();
  return PersonaRemoteDataSource(ref.watch(dioProvider));
});

/// 当前是否为「可展示个性化推荐」的登录用户。
///
/// 抽成单独 provider 是为了让测试能直接覆盖一个 bool，
/// 不必为了验游客态去搭整套会话状态机。
final personalizedAudienceProvider = Provider<bool>(
  (ref) => ref.watch(authControllerProvider).isSignedIn,
);

/// 画像页数据。
final personaInsightProvider = FutureProvider<PersonaInsight>((ref) async {
  // 游客不请求：`/api/me/profile` 要登录，硬打会拿 401，而 dio 的 401 拦截器
  // 会广播「会话已过期」——等于打开画像页把登录态踢掉。
  // 与 [PersonaRemoteDataSource.fetchFeed] 同一处理方式。
  if (!ref.watch(personalizedAudienceProvider)) {
    return const PersonaInsight(
      title: '',
      review: '',
      dimensions: <PersonaDimension>[],
    );
  }
  return ref.watch(personaDataSourceProvider).fetchInsight();
  // 所有 provider 都关掉 Riverpod 3 的自动重试：默认重试 10 次会留下 Timer，
  // 失败态变成 AsyncLoading(error:…) 一直挂在骨架屏上。
}, retry: (retryCount, error) => null);

/// 首页个性化区块数据。
final personaFeedProvider = FutureProvider<PersonaFeed>((ref) async {
  return ref.watch(personaDataSourceProvider).fetchFeed(
    signedIn: ref.watch(personalizedAudienceProvider),
  );
}, retry: (retryCount, error) => null);
