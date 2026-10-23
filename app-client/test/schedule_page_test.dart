import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:otaku_app/app.dart';
import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/core/router/app_router.dart';
import 'package:otaku_app/core/router/route_paths.dart';
import 'package:otaku_app/data/datasources/schedule_data_source.dart';
import 'package:otaku_app/data/datasources/collection_mock_data_source.dart';
import 'package:otaku_app/data/datasources/work_data_source.dart';
import 'package:otaku_app/data/models/paged_result.dart';
import 'package:otaku_app/data/models/related_works.dart';
import 'package:otaku_app/data/models/schedule.dart';
import 'package:otaku_app/data/models/work.dart';
import 'package:otaku_app/data/models/work_sort.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/data/repositories/collection_repository.dart';
import 'package:otaku_app/data/repositories/schedule_repository.dart';
import 'package:otaku_app/data/repositories/work_repository.dart';
import 'package:otaku_app/features/detail/work_detail_page.dart';
import 'package:otaku_app/features/schedule/schedule_page.dart';

import 'support/test_overrides.dart';

/// 可控的档期数据源：成功 / 失败 / 空三态，外加参数记录。
class _FakeScheduleSource implements ScheduleDataSource {
  _FakeScheduleSource({this.page, this.error});

  final SchedulePageData? page;
  final ApiException? error;
  final List<String?> seasonsQueried = [];

  @override
  Future<SchedulePageData> fetchSchedule({String? season}) async {
    seasonsQueried.add(season);
    final error = this.error;
    if (error != null) throw error;
    return page!;
  }
}

SchedulePageData _page({
  List<ScheduleGroup>? groups,
  List<String>? seasons,
}) {
  return SchedulePageData(
    season: '202610',
    seasons: seasons ?? const ['202610'],
    groups:
        groups ??
        const [
          ScheduleGroup(
            weekday: 1,
            label: '周一',
            items: [
              ScheduleEntry(
                scheduleId: 'S-1',
                title: '周一的新番',
                seasonCode: '202610',
                weekday: 1,
                broadcastTime: '22:30',
                tags: ['科幻'],
                workId: 'W-linked',
              ),
            ],
          ),
          ScheduleGroup(
            weekday: null,
            label: '待定',
            items: [
              ScheduleEntry(
                scheduleId: 'S-2',
                title: '待定的新番',
                seasonCode: '202610',
                weekday: null,
                workId: null,
              ),
            ],
          ),
        ],
  );
}

/// 详情页只需要一部作品：命中档期条目时点进去不能白屏。
class _FakeWorkSource implements WorkDataSource {
  @override
  Future<Work> fetchDetail(String workId) async => Work(
    workId: workId,
    workType: WorkType.anime,
    title: '被档期命中的作品',
  );

  @override
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    String? tag,
    WorkSort sort = WorkSort.id,
    int page = 1,
    int pageSize = 20,
  }) async => const PagedResult<WorkSummary>(
    items: [],
    total: 0,
    page: 1,
    pageSize: 20,
    totalPages: 0,
  );

  @override
  Future<RelatedWorks> fetchRelated(String workId, {int limit = 6}) async =>
      const RelatedWorks(basisTags: <String>[], items: <WorkSummary>[]);
}

Widget _app(ScheduleDataSource source) {
  final router = GoRouter(
    initialLocation: RoutePaths.schedule,
    routes: [
      GoRoute(
        path: RoutePaths.schedule,
        builder: (_, _) => const SchedulePage(),
      ),
      GoRoute(
        path: '${RoutePaths.contents}/:workId',
        builder: (context, state) => WorkDetailPage(
          workId: state.pathParameters['workId'] ?? '',
        ),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      ...authOverrides(),
      scheduleDataSourceProvider.overrideWithValue(source),
      workDataSourceProvider.overrideWithValue(_FakeWorkSource()),
      collectionDataSourceProvider.overrideWithValue(
        CollectionMockDataSource(delay: Duration.zero),
      ),
      appRouterProvider.overrideWithValue(router),
    ],
    child: const OtakuApp(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('默认展示全部，条目按顺序平铺', (tester) async {
    await tester.pumpWidget(_app(_FakeScheduleSource(page: _page())));
    await tester.pumpAndSettle();

    expect(find.text('周一的新番'), findsOneWidget);
    expect(find.text('待定的新番'), findsOneWidget);
    expect(find.text('22:30'), findsOneWidget);
    expect(find.text('2 部'), findsOneWidget);
  });

  testWidgets('选「周一」只留周一组，选「待定」只剩待定组', (tester) async {
    await tester.pumpWidget(_app(_FakeScheduleSource(page: _page())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('周一'));
    await tester.pumpAndSettle();
    expect(find.text('周一的新番'), findsOneWidget);
    expect(find.text('待定的新番'), findsNothing);

    await tester.tap(find.text('待定'));
    await tester.pumpAndSettle();
    expect(find.text('周一的新番'), findsNothing);
    expect(find.text('待定的新番'), findsOneWidget);
  });

  testWidgets('未命中本地作品的条目不可点，且说明原因', (tester) async {
    await tester.pumpWidget(_app(_FakeScheduleSource(page: _page())));
    await tester.pumpAndSettle();

    // 待定组那条 workId 为 null：说明文案出现，且卡片不可点。
    expect(find.text('本站未收录，仅展示档期信息'), findsOneWidget);

    await tester.tap(find.text('待定的新番'));
    await tester.pumpAndSettle();
    // 没有跳转到详情（仍在本页标题上）。
    expect(find.text('每日新番'), findsOneWidget);
  });

  testWidgets('命中本地作品的条目点击进详情', (tester) async {
    await tester.pumpWidget(_app(_FakeScheduleSource(page: _page())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('周一的新番'));
    await tester.pumpAndSettle();

    // 跳到了详情页（AppBar 标题变成作品详情）。
    expect(find.text('作品详情'), findsOneWidget);
  });

  testWidgets('请求失败显示错误态与重试，不白屏', (tester) async {
    final source = _FakeScheduleSource(
      error: const ApiException(
        code: ApiErrorCode.network,
        message: '网络异常',
      ),
    );
    await tester.pumpWidget(_app(source));
    await tester.pumpAndSettle();

    // network 类错误的用户文案由 ApiException.userMessage 统一生成
    // （不是 message 原文），这里是错误态 + 重试入口在的证明。
    expect(find.text('网络连接失败，请检查网络后重试'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('空档期（无条目）显示空状态，不报错', (tester) async {
    final source = _FakeScheduleSource(
      page: _page(
        groups: const [ScheduleGroup(weekday: 1, label: '周一', items: [])],
      ),
    );
    await tester.pumpWidget(_app(source));
    await tester.pumpAndSettle();

    expect(find.text('还没有档期数据'), findsOneWidget);
  });

  testWidgets('某一天没有条目：显示「这天没有新番」', (tester) async {
    await tester.pumpWidget(_app(_FakeScheduleSource(page: _page())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('周三'));
    await tester.pumpAndSettle();
    expect(find.text('这天没有新番'), findsOneWidget);
  });

  testWidgets('多个季度才显示切换入口；切换带 season 重新请求', (tester) async {
    final source = _FakeScheduleSource(
      page: _page(seasons: const ['202610', '202607']),
    );
    await tester.pumpWidget(_app(source));
    await tester.pumpAndSettle();

    // 首次请求不带 season（走后端默认）
    expect(source.seasonsQueried, [null]);

    await tester.tap(find.byTooltip('切换季度'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2026 年 7 月'));
    await tester.pumpAndSettle();

    expect(source.seasonsQueried.last, '202607');
  });
}
