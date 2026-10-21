import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/app.dart';
import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/data/datasources/work_data_source.dart';
import 'package:otaku_app/data/datasources/work_mock_data_source.dart';
import 'package:otaku_app/data/models/paged_result.dart';
import 'package:otaku_app/data/models/work.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/data/repositories/work_repository.dart';
import 'package:otaku_app/features/contents/contents_controller.dart';
import 'package:otaku_app/features/contents/contents_page.dart';
import 'package:otaku_app/features/contents/work_card.dart';
import 'package:otaku_app/features/contents/work_list_tile.dart';
import 'package:otaku_app/features/detail/work_detail_page.dart';

import 'support/test_overrides.dart';

/// 内存数据源：不读资源、不发网络，让 widget 测试只关注界面。
/// 资源与分页语义由下面的 [MockWorkDataSource] 测试覆盖。
class _FakeDataSource implements WorkDataSource {
  static final longSummary = List.filled(
    60,
    '这是一段很长的简介，用来验证折叠。',
  ).join();

  static const summaryItem = WorkSummary(
    workId: 'W-1',
    workType: WorkType.anime,
    title: '铁臂阿童木',
    // 契约 6.3：没有封面、没有评分、没有标签，界面必须自己兜住。
  );

  @override
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    int page = 1,
    int pageSize = 20,
  }) async {
    return const PagedResult<WorkSummary>(
      items: [summaryItem, summaryItem, summaryItem],
      total: 3,
      page: 1,
      pageSize: 20,
      totalPages: 1,
    );
  }

  @override
  Future<Work> fetchDetail(String workId) async {
    if (workId != summaryItem.workId) {
      throw const ApiException(
        code: ApiErrorCode.workNotFound,
        message: '作品不存在',
        statusCode: 404,
      );
    }
    return Work(
      workId: summaryItem.workId,
      workType: WorkType.anime,
      title: summaryItem.title,
      summary: longSummary,
      source: 'otaku_site',
      sourceId: '662',
      updatedAt: DateTime.utc(2026, 10, 19, 15, 28, 57),
    );
  }
}

/// 不筛选时正常返回，一旦按类型筛选就断网——用来复现"换条件后请求失败"。
class _OfflineOnFilterDataSource extends _FakeDataSource {
  @override
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    int page = 1,
    int pageSize = 20,
  }) async {
    if (type != null) {
      throw const ApiException(
        code: ApiErrorCode.network,
        message: '网络连接失败',
      );
    }
    return super.fetchWorks(type: type, query: query, page: page);
  }
}

/// 第一次成功、之后全部失败——用来复现"同条件刷新失败"。
class _OfflineAfterFirstLoadDataSource extends _FakeDataSource {
  int calls = 0;

  @override
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    int page = 1,
    int pageSize = 20,
  }) async {
    calls++;
    if (calls > 1) {
      throw const ApiException(
        code: ApiErrorCode.network,
        message: '网络连接失败',
      );
    }
    return super.fetchWorks(type: type, query: query, page: page);
  }
}

/// 这些测试直接读 `assets/mock/` 里的真实样本，校验资源是否已声明进 pubspec，
/// 以及 Mock 数据源是否保留了契约要求的查询语义。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child, {WorkDataSource? source}) {
    return ProviderScope(
      overrides: [
        workDataSourceProvider.overrideWithValue(source ?? _FakeDataSource()),
        // 详情页与列表页都会碰认证状态（账号入口、收藏区），不让它走平台通道。
        ...authOverrides(),
      ],
      child: child,
    );
  }

  /// 第一帧是骨架屏，异步结果要多走一帧才会落到界面上。
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  group('MockWorkDataSource', () {
    test('24 条数据按 20 条分页，共两页', () async {
      final source = MockWorkDataSource(latency: Duration.zero);

      // 显式给 pageSize：这条测的是分页机制，不该被 AppConfig.pageSize 的默认值牵着走
      // （它已经从 20 提到 50，否则这里 24 条一页就完了，测不到「翻页」）。
      final first = await source.fetchWorks(page: 1, pageSize: 20);
      expect(first.total, 24);
      expect(first.items, hasLength(20));
      expect(first.hasNext, isTrue);

      final second = await source.fetchWorks(page: 2, pageSize: 20);
      expect(second.items, hasLength(4));
      expect(second.hasNext, isFalse);
    });

    test('搜索只匹配标题子串，且忽略大小写', () async {
      final source = MockWorkDataSource(latency: Duration.zero);
      final result = await source.fetchWorks(query: 'nhk');
      expect(result.total, 1);
      expect(result.items.single.title, 'NHK15个动画短片');
    });

    test('同名作品各自独立，不按标题去重', () async {
      final source = MockWorkDataSource(latency: Duration.zero);
      final result = await source.fetchWorks(query: '铁臂阿童木');
      expect(result.total, 3);
      expect(result.items.map((e) => e.workId).toSet(), hasLength(3));
    });

    test('按类型筛选', () async {
      final source = MockWorkDataSource(latency: Duration.zero);
      final result = await source.fetchWorks(type: WorkType.game);
      expect(result.total, 2);
      expect(result.items, isNotEmpty);
    });

    test('详情不存在时抛 WORK_NOT_FOUND', () async {
      final source = MockWorkDataSource(latency: Duration.zero);
      await expectLater(
        source.fetchDetail('W-not-exist'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            ApiErrorCode.workNotFound,
          ),
        ),
      );
    });
  });

  testWidgets('列表页渲染卡片，缺封面/评分/标签时不崩', (tester) async {
    await tester.pumpWidget(wrap(const OtakuApp()));
    await settle(tester);

    expect(find.text('作品库'), findsOneWidget);
    expect(find.byType(WorkCard), findsNWidgets(3));
    expect(find.text('铁臂阿童木'), findsNWidgets(3));

    // 没有评分就不该出现评分徽标，更不能出现 0.0。
    expect(find.text('0.0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情 404 提示作品不存在，且不给重试按钮', (tester) async {
    await tester.pumpWidget(
      wrap(const MaterialApp(home: WorkDetailPage(workId: 'W-404'))),
    );
    await settle(tester);

    expect(find.text('作品不存在'), findsOneWidget);
    expect(find.text('返回列表'), findsOneWidget);
    // 契约 6.2：404 不自动重试，也不该出现重试按钮。
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('详情页渲染标题，超长简介默认折叠', (tester) async {
    // 默认视口只有 800x600，展开按钮会落在屏幕外点不到。
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      wrap(const MaterialApp(home: WorkDetailPage(workId: 'W-1'))),
    );
    await settle(tester);

    expect(find.text('作品详情'), findsOneWidget);
    expect(find.text('铁臂阿童木'), findsOneWidget);
    expect(find.text('展开全文'), findsOneWidget);

    // 点一下展开，按钮变成"收起"。
    await tester.tap(find.text('展开全文'));
    await tester.pump();
    expect(find.text('收起'), findsOneWidget);
  });

  testWidgets('换类型后请求失败：报错并可重试，不把旧类型的结果当新结果', (tester) async {
    await tester.pumpWidget(
      wrap(const OtakuApp(), source: _OfflineOnFilterDataSource()),
    );
    await settle(tester);
    expect(find.byType(WorkCard), findsNWidgets(3));

    await tester.tap(find.widgetWithText(ChoiceChip, '动画'));
    await settle(tester);

    // 旧结果必须让位给错误状态：切到"动画"却还显示全部类型的三条卡片是误导。
    expect(find.byType(WorkCard), findsNothing);
    expect(find.text('网络好像不太行'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同一条件刷新失败：保留内容，但显示错误提示条与重试', (tester) async {
    final source = _OfflineAfterFirstLoadDataSource();
    await tester.pumpWidget(wrap(const OtakuApp(), source: source));
    await settle(tester);
    expect(find.byType(WorkCard), findsNWidgets(3));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ContentsPage)),
    );
    await container.read(contentsControllerProvider.notifier).refresh();
    await settle(tester);

    // 内容还在，但失败必须说清楚，不能静默。
    expect(find.byType(WorkCard), findsNWidgets(3));
    expect(find.text('网络连接失败，请检查网络后重试'), findsOneWidget);
    expect(
      find.widgetWithText(TextButton, '重试'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('筛选胶囊显示作品数，数量来自列表接口的 total', (tester) async {
    await tester.pumpWidget(wrap(const OtakuApp()));
    await settle(tester);

    // _FakeDataSource 对每个类型都返回 total = 3。
    for (final label in ['全部', '动画', '漫画', '游戏', '小说']) {
      expect(
        find.descendant(
          of: find.widgetWithText(ChoiceChip, label),
          matching: find.text('3'),
        ),
        findsOneWidget,
        reason: '「$label」胶囊上应该带作品数',
      );
    }
    expect(find.text('共 3 部'), findsOneWidget);
  });

  testWidgets('切到列表视图：卡片换成行式，总数不变', (tester) async {
    await tester.pumpWidget(wrap(const OtakuApp()));
    await settle(tester);
    expect(find.byType(WorkCard), findsNWidgets(3));

    await tester.tap(find.byTooltip('列表视图'));
    await settle(tester);

    expect(find.byType(WorkListTile), findsNWidgets(3));
    expect(find.byType(WorkCard), findsNothing);

    // 切回网格，状态要能来回切。
    await tester.tap(find.byTooltip('网格视图'));
    await settle(tester);
    expect(find.byType(WorkCard), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情页列出收录信息，缺失的行不占位', (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      wrap(const MaterialApp(home: WorkDetailPage(workId: 'W-1'))),
    );
    await settle(tester);

    expect(find.text('收录信息'), findsOneWidget);
    // 作品 ID / 来源 / 来源 ID / 收录更新 四行都来自假数据源。
    expect(find.text('W-1'), findsOneWidget);
    expect(find.text('otaku_site'), findsOneWidget);
    expect(find.text('662'), findsOneWidget);
    expect(find.text('2026-10-19'), findsOneWidget);
    // 假数据没有封面、没有评分、没有标签：不该凭空出现「0.0」或空标签区。
    expect(find.text('0.0'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
