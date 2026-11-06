import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/core/platform_info.dart';
import 'package:otaku_app/core/theme/app_theme.dart';
import 'package:otaku_app/data/datasources/person_data_source.dart';
import 'package:otaku_app/data/models/person_detail.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/features/contents/work_list_tile.dart';
import 'package:otaku_app/features/person/person_page.dart';
import 'package:otaku_app/shared/widgets/empty_state.dart';
import 'package:otaku_app/shared/widgets/error_state.dart';

class _FakePersonSource implements PersonDataSource {
  _FakePersonSource({this.detail, this.error});

  final PersonDetail? detail;
  final Object? error;
  int calls = 0;

  @override
  Future<PersonDetail> fetch(String personId) async {
    calls++;
    if (error != null) throw error!;
    return detail!;
  }
}

PersonDetail _detail({bool empty = false}) => PersonDetail(
  personId: 'P-1',
  personName: '测试声优',
  entityType: 'person',
  castCount: empty ? 0 : 2,
  creditCount: empty ? 0 : 1,
  works: empty
      ? const <PersonCredit>[]
      : [
          PersonCredit(
            work: const WorkSummary(
              workId: 'W-1',
              workType: WorkType.anime,
              title: '既有配音又有制作',
            ),
            characters: const ['鹿目圆'],
            roles: const ['主题歌'],
          ),
          PersonCredit(
            work: const WorkSummary(
              workId: 'W-2',
              workType: WorkType.anime,
              title: '只配音',
            ),
            characters: const ['路人甲'],
          ),
        ],
);

void main() {
  Future<void> pumpPerson(
    WidgetTester tester,
    _FakePersonSource source,
  ) async {
    PlatformInfo.desktopOverride = false;
    addTearDown(PlatformInfo.resetOverride);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final router = GoRouter(
      initialLocation: '/persons/P-1',
      routes: [
        GoRoute(
          path: '/persons/:personId',
          builder: (_, state) =>
              PersonPage(personId: state.pathParameters['personId'] ?? ''),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [personDataSourceProvider.overrideWithValue(source)],
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('有参与作品：名字、统计、两类身份分行，一句一条作品卡', (tester) async {
    await pumpPerson(tester, _FakePersonSource(detail: _detail()));

    expect(find.text('测试声优'), findsAtLeastNWidgets(1));
    expect(find.text('配音 2 部 · 制作 1 部'), findsOneWidget);
    expect(find.byType(WorkListTile), findsNWidgets(2));

    // 同一部作品既配音又制作：只出一张卡，但两行身份分开写。
    // 这两行是 Text.rich（渲染成 RichText），find 必须开 findRichText。
    expect(
      find.textContaining('配音：鹿目圆', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('配音：路人甲', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('制作：主题歌', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('没有可展示作品：给空态，不是空白页也不报错', (tester) async {
    await pumpPerson(
      tester,
      _FakePersonSource(detail: _detail(empty: true)),
    );

    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('这个人还没有可展示的作品'), findsOneWidget);
    expect(find.byType(WorkListTile), findsNothing);
  });

  testWidgets('404 说「人物不存在」，且不给重试按钮', (tester) async {
    await pumpPerson(
      tester,
      _FakePersonSource(
        error: const ApiException(
          code: ApiErrorCode.unknown,
          message: '人物不存在',
          statusCode: 404,
        ),
      ),
    );

    expect(find.byType(ErrorState), findsOneWidget);
    expect(find.text('人物不存在'), findsOneWidget);
    // 契约：404 不给重试——再点一次还是 404。
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('其它错误给重试入口', (tester) async {
    await pumpPerson(
      tester,
      _FakePersonSource(
        error: const ApiException(
          code: ApiErrorCode.unknown,
          message: '网络好像不太行',
          statusCode: 500,
        ),
      ),
    );

    expect(find.byType(ErrorState), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });
}
