import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:otaku_app/app.dart';
import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/data/datasources/collection_mock_data_source.dart';
import 'package:otaku_app/data/datasources/work_data_source.dart';
import 'package:otaku_app/data/datasources/work_mock_data_source.dart';
import 'package:otaku_app/data/models/paged_result.dart';
import 'package:otaku_app/data/models/related_works.dart';
import 'package:otaku_app/data/models/source_rating.dart';
import 'package:otaku_app/data/models/work.dart';
import 'package:otaku_app/data/models/work_sort.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/data/repositories/collection_repository.dart';
import 'package:otaku_app/data/repositories/work_repository.dart';
import 'package:otaku_app/features/detail/work_detail_page.dart';
import 'package:otaku_app/core/router/app_router.dart';
import 'package:otaku_app/core/router/route_paths.dart';

import 'support/test_overrides.dart';

/// 记录每次列表请求的 sort / page：排序是服务端的事，客户端要证明的是
/// **把用户选的值原样发了出去**，并且翻页时带的是同一个。
class _RecordingWorkSource implements WorkDataSource {
  _RecordingWorkSource({this.related, this.relatedError});

  final List<WorkSort> sorts = <WorkSort>[];
  final List<int> pages = <int>[];
  final RelatedWorks? related;
  final ApiException? relatedError;
  int relatedCalls = 0;

  @override
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    WorkSort sort = WorkSort.id,
    int page = 1,
    int pageSize = 20,
    List<String>? tags,
  
    int? year,}) async {
    sorts.add(sort);
    pages.add(page);
    return PagedResult<WorkSummary>(
      items: const [
        WorkSummary(workId: 'W-1', workType: WorkType.anime, title: '甲'),
      ],
      total: 1,
      page: page,
      pageSize: pageSize,
      totalPages: 1,
    );
  }

  @override
  Future<Work> fetchDetail(String workId) async => Work(
    workId: workId,
    workType: WorkType.anime,
    title: '甲',
    tags: const ['科幻'],
  );

  @override
  Future<RelatedWorks> fetchRelated(String workId, {int limit = 6}) async {
    relatedCalls++;
    final error = relatedError;
    if (error != null) throw error;
    return related ?? const RelatedWorks(basisTags: [], items: []);
  }
}

WorkSummary _summary(
  String id,
  String title, {
  double? rating,
  int? year,
  List<String>? tags,
}) =>
    WorkSummary(
      workId: id,
      workType: WorkType.anime,
      title: title,
      releaseYear: year,
      tags: tags,
      mainRating: rating == null
          ? null
          : SourceRating(value: rating, scale: '0-10', source: 't'),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WorkSort', () {
    test('三种取值与契约一致', () {
      expect(WorkSort.values.map((s) => s.value).toList(), [
        'id',
        'rating',
        'year',
      ]);
    });

    test('未知取值退回 id，不抛错', () {
      expect(WorkSort.fromValue('zzz'), WorkSort.id);
      expect(WorkSort.fromValue(null), WorkSort.id);
    });
  });

  group('RelatedWorks.fromJson', () {
    test('按契约解析 basis_tags 与 items', () {
      final parsed = RelatedWorks.fromJson({
        'basis_tags': ['科幻', '机战'],
        'items': [
          {
            'work_id': 'W-9',
            'work_type': 'anime',
            'title': '乙',
            'tags': ['科幻'],
            'main_rating': {
              'value': 8.1,
              'scale': '0-10',
              'source': 'bangumi',
            },
          },
        ],
      });

      expect(parsed.basisTags, ['科幻', '机战']);
      expect(parsed.items.single.workId, 'W-9');
      expect(parsed.items.single.mainRating?.value, 8.1);
      expect(parsed.isEmpty, isFalse);
    });

    test('字段缺失时归一为空结果，不抛错', () {
      final parsed = RelatedWorks.fromJson(<String, dynamic>{});
      expect(parsed.basisTags, isEmpty);
      expect(parsed.items, isEmpty);
      expect(parsed.isEmpty, isTrue);
    });
  });

  Widget listApp(WorkDataSource source) => ProviderScope(
    overrides: [
      appInitialLocationProvider.overrideWithValue(RoutePaths.contents),
      ...authOverrides(),
      workDataSourceProvider.overrideWithValue(source),
    ],
    child: const OtakuApp(),
  );

  Widget detailApp(WorkDataSource source) => ProviderScope(
    overrides: [
      ...authOverrides(),
      workDataSourceProvider.overrideWithValue(source),
      collectionDataSourceProvider.overrideWithValue(
        CollectionMockDataSource(delay: Duration.zero),
      ),
    ],
    child: MaterialApp(home: WorkDetailPage(workId: 'W-1')),
  );

  testWidgets('列表默认按入库顺序请求，切到「评分最高」后带 sort=rating', (
    tester,
  ) async {
    final source = _RecordingWorkSource();
    await tester.pumpWidget(listApp(source));
    await tester.pumpAndSettle();

    // 不断言请求次数：`pumpAndSettle` 会跑很多帧，框架重 build 的次数与
    // 生产无关。要验的是"发出去的值"。
    expect(source.sorts.first, WorkSort.id);

    await tester.tap(find.byTooltip('排序（当前：入库顺序）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('评分最高'));
    await tester.pumpAndSettle();

    // 换排序等于换条件：重新查第一页，而不是接着翻上一组的页。
    expect(source.sorts.last, WorkSort.rating);
    expect(source.pages.last, 1);
  });

  testWidgets('相关作品有结果时渲染区块并说明匹配理由', (tester) async {
    final source = _RecordingWorkSource(
      related: RelatedWorks(
        basisTags: const ['科幻', '机战'],
        items: [_summary('W-2', '相关作品乙', rating: 8.2)],
      ),
    );
    await tester.pumpWidget(detailApp(source));
    await tester.pumpAndSettle();

    expect(find.text('相关作品'), findsOneWidget);
    expect(find.text('同题材：科幻、机战'), findsOneWidget);
    expect(find.text('相关作品乙'), findsOneWidget);
    expect(source.relatedCalls, 1);
  });

  testWidgets('作品没有标签（空结果）：整块不渲染，不显示「暂无推荐」', (tester) async {
    final source = _RecordingWorkSource(
      related: const RelatedWorks(basisTags: [], items: []),
    );
    await tester.pumpWidget(detailApp(source));
    await tester.pumpAndSettle();

    expect(find.text('相关作品'), findsNothing);
    // 正文照常显示：推荐为空不等于这页出错。
    expect(find.text('甲'), findsWidgets);
  });

  testWidgets('推荐请求失败：整块不渲染，详情正文不受牵连', (tester) async {
    final source = _RecordingWorkSource(
      relatedError: const ApiException(
        code: ApiErrorCode.network,
        message: '网络异常',
      ),
    );
    await tester.pumpWidget(detailApp(source));
    await tester.pumpAndSettle();

    expect(find.text('相关作品'), findsNothing);
    expect(find.text('网络异常'), findsNothing);
    expect(find.text('甲'), findsWidgets);
  });

  group('MockWorkDataSource（USE_MOCK=true 时的同源行为）', () {
    /// 直接问 Mock 数据源要结果，而不是复制一份比较器来测：
    /// 复制品改了生产代码也还是绿的，等于没测。
    Future<List<String>> mockOrder(WorkSort sort) async {
      final source = MockWorkDataSource(
        bundle: _FakeBundle(_catalogJson()),
        latency: Duration.zero,
      );
      final result = await source.fetchWorks(sort: sort, pageSize: 50);
      return result.items.map((w) => w.workId).toList();
    }

    test('默认按入库顺序', () async {
      expect(await mockOrder(WorkSort.id), ['W-1', 'W-2', 'W-3', 'W-4']);
    });

    test('评分降序、无评分沉底', () async {
      // W-3 无评分；W-2(9.1) > W-4(7.5) > W-1(6.0)
      expect(await mockOrder(WorkSort.rating), ['W-2', 'W-4', 'W-1', 'W-3']);
    });

    test('年份降序、无年份沉底', () async {
      // W-4 无年份；W-3(2021) > W-2(2015) > W-1(2008)
      expect(await mockOrder(WorkSort.year), ['W-3', 'W-2', 'W-1', 'W-4']);
    });

    test('同标签推荐：排除自己、按评分降序、返回参与匹配的标签', () async {
      final source = MockWorkDataSource(
        bundle: _FakeBundle(_catalogJson()),
        latency: Duration.zero,
      );
      final related = await source.fetchRelated('W-1');
      // W-1 的标签是 [科幻, 机战]；命中 W-2(科幻/9.1) 与 W-3(机战/无评分)。
      expect(related.basisTags, ['科幻', '机战']);
      expect(related.items.map((w) => w.workId).toList(), ['W-2', 'W-3']);
    });

    test('作品没标签 → 空结果而不是报错', () async {
      final source = MockWorkDataSource(
        bundle: _FakeBundle(_catalogJson()),
        latency: Duration.zero,
      );
      final related = await source.fetchRelated('W-4');
      expect(related.isEmpty, isTrue);
    });

    test('作品不存在 → 404（与详情一致）', () async {
      final source = MockWorkDataSource(
        bundle: _FakeBundle(_catalogJson()),
        latency: Duration.zero,
      );
      await expectLater(
        source.fetchRelated('W-nope'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.isNotFound,
            'isNotFound',
            isTrue,
          ),
        ),
      );
    });
  });
}

/// 给 Mock 数据源喂自定义目录：`AssetBundle` 只需实现 `load`，
/// `loadString` 的默认实现会走它。
class _FakeBundle extends AssetBundle {
  _FakeBundle(this._text);

  final Map<String, String> _text;

  @override
  Future<ByteData> load(String key) async {
    final raw = _text[key];
    if (raw == null) throw ArgumentError('未提供的资源: $key');
    final bytes = utf8.encode(raw);
    final data = ByteData(bytes.length);
    for (var i = 0; i < bytes.length; i++) {
      data.setUint8(i, bytes[i]);
    }
    return data;
  }
}

/// 四条样本：评分/年份各留一条空值，用来验证「null 沉底」。
Map<String, String> _catalogJson() => {
  'assets/mock/works_catalog.json': jsonEncode({
    'items': [
      {
        'work_id': 'W-1',
        'work_type': 'anime',
        'title': '甲',
        'release_year': 2008,
        'tags': ['科幻', '机战'],
        'main_rating': {'value': 6.0, 'scale': '0-10', 'source': 't'},
      },
      {
        'work_id': 'W-2',
        'work_type': 'anime',
        'title': '乙',
        'release_year': 2015,
        'tags': ['科幻'],
        'main_rating': {'value': 9.1, 'scale': '0-10', 'source': 't'},
      },
      {
        'work_id': 'W-3',
        'work_type': 'comic',
        'title': '丙',
        'release_year': 2021,
        'tags': ['机战'],
      },
      {
        'work_id': 'W-4',
        'work_type': 'game',
        'title': '丁',
        'main_rating': {'value': 7.5, 'scale': '0-10', 'source': 't'},
      },
    ],
    'total': 4,
    'page': 1,
    'page_size': 50,
    'total_pages': 1,
  }),
};
