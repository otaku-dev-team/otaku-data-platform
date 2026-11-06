import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:otaku_app/features/persona/persona_data_source.dart';
import 'package:otaku_app/features/persona/persona_mock_data.dart';
import 'package:otaku_app/features/persona/persona_page.dart';
import 'package:otaku_app/features/persona/persona_radar_chart.dart';
import 'package:otaku_app/features/persona/persona_view_data.dart';
import 'package:otaku_app/features/persona/personalized_recommend_section.dart';

/// #375 / #376 UI 壳的四态与游客回落。
///
/// 只钉「用户看得见」的事：登录才出个性化榜、游客出引导卡、失败给重试、
/// 画像页画得出六维雷达。数据一律走假数据源，不碰 #401 / #402 真接口，
/// 也不依赖 Hive（provider 全用 overrideWithValue）。
void main() {
  Widget host(
    Widget child, {
    required PersonaDataSource source,
    bool signedIn = true,
    bool withRouter = false,
  }) {
    final container = ProviderContainer(
      overrides: [
        personaDataSourceProvider.overrideWithValue(source),
        // 直接覆盖一个 bool，不用为验游客态搭整套会话状态机。
        personalizedAudienceProvider.overrideWithValue(signedIn),
      ],
    );
    final app = withRouter
        ? MaterialApp.router(
            routerConfig: GoRouter(
              routes: [
                GoRoute(path: '/', builder: (_, _) => child),
              ],
            ),
          )
        : MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: child)),
          );
    return UncontrolledProviderScope(container: container, child: app);
  }

  testWidgets('登录用户看到个性化推荐与理由标签', (tester) async {
    await tester.pumpWidget(
      host(
        const PersonalizedRecommendSection(),
        source: const PersonaMockDataSource(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('为你推荐'), findsOneWidget);
    expect(find.text('银河边缘的旧书店'), findsOneWidget);
    expect(find.text('你偏爱的科幻题材'), findsOneWidget);
  });

  testWidgets('游客回落：不渲染个性化榜，只给登录引导', (tester) async {
    await tester.pumpWidget(
      host(
        const PersonalizedRecommendSection(),
        source: const PersonaMockDataSource(),
        signedIn: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('登录后'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
    expect(find.text('银河边缘的旧书店'), findsNothing);
  });

  testWidgets('失败态给出重试，重试后恢复', (tester) async {
    final source = _FlakyDataSource(failTimes: 1);
    await tester.pumpWidget(
      host(const PersonalizedRecommendSection(), source: source),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂时取不到数据'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('暂时取不到数据'), findsNothing);
    expect(find.text('银河边缘的旧书店'), findsOneWidget);
  });

  testWidgets('空态：有响应但没有候选作品', (tester) async {
    await tester.pumpWidget(
      host(
        const PersonalizedRecommendSection(),
        source: _EmptyFeedDataSource(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂时没有为你挑出作品'), findsOneWidget);
    expect(find.text('银河边缘的旧书店'), findsNothing);
  });

  testWidgets('画像页渲染六维雷达、锐评与待接口入口', (tester) async {
    await tester.pumpWidget(
      host(
        const PersonaPage(),
        source: const PersonaMockDataSource(),
        withRouter: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PersonaRadarChart), findsOneWidget);
    expect(find.text('深夜考据派'), findsOneWidget);
    expect(find.textContaining('设定集'), findsOneWidget);
    expect(find.text('阿宅画像'), findsOneWidget);
    // 这里用的是假数据源，验的是「页面能渲染任何 PersonaInsight」——
    // 真数据下长什么样由 PersonaInsightMapper 决定（见同名 _test 文件）。
    // 「待接口」那一排在 ListView 底部，默认视口里可能还没被 build，
    // 这里不钉它的数量，只钉首屏能看见的内容。
  });
}

class _FlakyDataSource implements PersonaDataSource {
  _FlakyDataSource({required this.failTimes});

  int failTimes;

  @override
  Future<PersonaInsight> fetchInsight() async => kShellPersonaInsight;

  @override
  Future<PersonaFeed> fetchFeed({required bool signedIn}) async {
    if (failTimes > 0) {
      failTimes--;
      throw StateError('mock fetch failed');
    }
    return PersonaFeed(
      isGuest: !signedIn,
      items: signedIn ? kShellRecommendations : const <RecommendedWork>[],
    );
  }
}

class _EmptyFeedDataSource implements PersonaDataSource {
  @override
  Future<PersonaInsight> fetchInsight() async => kShellPersonaInsight;

  @override
  Future<PersonaFeed> fetchFeed({required bool signedIn}) async =>
      const PersonaFeed(isGuest: false);
}
