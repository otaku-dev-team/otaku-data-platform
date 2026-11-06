import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:otaku_app/app.dart';
import 'package:otaku_app/core/platform_info.dart';
import 'package:otaku_app/core/router/app_router.dart';
import 'package:otaku_app/core/router/route_paths.dart';
import 'package:otaku_app/data/datasources/collection_mock_data_source.dart';
import 'package:otaku_app/data/datasources/work_data_source.dart';
import 'package:otaku_app/data/models/paged_result.dart';
import 'package:otaku_app/data/models/related_works.dart';
import 'package:otaku_app/data/models/work.dart';
import 'package:otaku_app/data/models/work_sort.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/data/repositories/collection_repository.dart';
import 'package:otaku_app/data/repositories/work_repository.dart';
import 'package:otaku_app/features/detail/view_report.dart';

import 'support/test_overrides.dart';

const String _workId = 'W-view-test';

/// 详情页打开时向服务端报一次浏览（`POST /api/me/views`）。
///
/// 钉两件事：
/// 1. **登录用户打开详情页报一次**——不报的话 `user_work_view` 永远是空表，
///    画像与推荐都少掉最强的一路信号；
/// 2. **游客一个请求都不报**——401 会被 dio 拦截器广播成「会话过期」，
///    等于看个详情页把登录态踢掉。
void main() {
  Future<_FakeReporter> pumpDetail(
    WidgetTester tester, {
    bool signedIn = true,
  }) async {
    final reporter = _FakeReporter();
    PlatformInfo.desktopOverride = false;
    addTearDown(PlatformInfo.resetOverride);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...authOverrides(token: signedIn ? signedInToken : null),
          ...tagOverrides(),
          appInitialLocationProvider.overrideWithValue(
            RoutePaths.workDetail(_workId),
          ),
          workDataSourceProvider.overrideWithValue(_DetailSource()),
          // 默认 mock 带 300ms 延迟，会把 pumpAndSettle 拖成「一直加载」。
          collectionDataSourceProvider.overrideWithValue(
            CollectionMockDataSource(delay: Duration.zero),
          ),
          viewReporterProvider.overrideWithValue(reporter),
        ],
        child: const OtakuApp(),
      ),
    );
    await tester.pumpAndSettle();
    return reporter;
  }

  testWidgets('登录用户打开详情页：报一次浏览', (tester) async {
    final reporter = await pumpDetail(tester);

    // 先确认详情真的渲染出来了：否则「没报」可能只是详情压根没加载。
    expect(find.text('打点测试作品'), findsOneWidget);
    // 恰好一次：`_remember` 可能被缓存值与网络值各触发一次，
    // 同一次访问算两次浏览会让 view_count 虚高。
    expect(reporter.workIds, <String>[_workId]);
  });

  testWidgets('游客打开详情页：一个请求都不报', (tester) async {
    final reporter = await pumpDetail(tester, signedIn: false);

    expect(reporter.workIds, isEmpty);
  });
}

class _FakeReporter implements ViewReporter {
  final List<String> workIds = <String>[];

  @override
  Future<void> report(String workId) async {
    workIds.add(workId);
  }
}

class _DetailSource implements WorkDataSource {
  @override
  Future<Work> fetchDetail(String workId) async => Work(
    workId: workId,
    workType: WorkType.anime,
    title: '打点测试作品',
    releaseYear: 2026,
    tags: const <String>['冒险'],
  );

  @override
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    WorkSort sort = WorkSort.id,
    int page = 1,
    int pageSize = 20,
    List<String>? tags,
    int? year,
  }) async => PagedResult(
    items: const <WorkSummary>[],
    total: 0,
    page: page,
    pageSize: pageSize,
    totalPages: 0,
  );

  @override
  Future<RelatedWorks> fetchRelated(String workId, {int limit = 6}) async =>
      const RelatedWorks(basisTags: <String>[], items: <WorkSummary>[]);
}
