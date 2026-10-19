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
import 'package:otaku_app/features/contents/work_card.dart';
import 'package:otaku_app/features/detail/work_detail_page.dart';

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

/// 这些测试直接读 `assets/mock/` 里的真实样本，校验资源是否已声明进 pubspec，
/// 以及 Mock 数据源是否保留了契约要求的查询语义。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child) {
    return ProviderScope(
      overrides: [
        workDataSourceProvider.overrideWithValue(_FakeDataSource()),
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

      final first = await source.fetchWorks(page: 1);
      expect(first.total, 24);
      expect(first.items, hasLength(20));
      expect(first.hasNext, isTrue);

      final second = await source.fetchWorks(page: 2);
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
}
