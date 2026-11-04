import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import 'persona_mock_data.dart';
import 'persona_view_data.dart';

/// 画像 / 个性化推荐的**唯一数据入口**。
///
/// 目前只有 mock 实现，因为 #401（画像 API）与 #402（推荐 API）还没落地，
/// 且 `docs/algorithm-design.md` §7 的画像 schema、推荐返回结构仍未定稿。
/// 这里不写 URL、不写 DTO、不猜字段名——**真数据联调等接口**。
///
/// 接接口时的改动清单（其它文件不用动）：
/// 1. 新增 `PersonaRemoteDataSource implements PersonaDataSource`，在里面
///    按定稿契约做 JSON → [PersonaInsight] / [PersonaFeed] 的映射
///    （规则 key 翻译成理由文案、权重归一化成 0..1 也在这里做）；
/// 2. 在 [personaDataSourceProvider] 里按 `AppConfig.useMock` 切换，
///    与其余 repository 的写法保持一致；
/// 3. 删掉 `persona_mock_data.dart`。
abstract interface class PersonaDataSource {
  Future<PersonaInsight> fetchInsight();

  /// [signedIn] 由页面层传入：游客不请求个性化接口（#376 回落默认榜）。
  Future<PersonaFeed> fetchFeed({required bool signedIn});
}

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

/// 换实现只改这一个 provider。测试用 `overrideWithValue` 注入假数据源。
final personaDataSourceProvider = Provider<PersonaDataSource>(
  (ref) => const PersonaMockDataSource(),
);

/// 当前是否为「可展示个性化推荐」的登录用户。
///
/// 抽成单独 provider 是为了让测试能直接覆盖一个 bool，
/// 不必为了验游客态去搭整套会话状态机。
final personalizedAudienceProvider = Provider<bool>(
  (ref) => ref.watch(authControllerProvider).isSignedIn,
);

/// 画像页数据。
final personaInsightProvider = FutureProvider<PersonaInsight>((ref) async {
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
