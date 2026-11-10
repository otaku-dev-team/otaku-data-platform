import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:otaku_app/data/models/series_page.dart';
import 'package:otaku_app/data/models/work_series.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/features/detail/work_series_section.dart';
import 'package:otaku_app/features/series/series_data_source.dart';

/// #411 / #557 详情页「系列作品」区。
///
/// 钉的是 `{relation, work}` 这一层包装（漏解一层会整块消失）、
/// `series_name` 为 null 时不拿 key 顶替、以及空结果整块不渲染。
void main() {
  group('模型', () {
    test('relation 四个取值映射对，未知值回落同系列', () {
      const values = <String, String>{
        'prequel': '前作',
        'sequel': '续作',
        'spin_off': '衍生作',
        'same_series': '同系列',
        'something_new': '同系列',
      };
      for (final entry in values.entries) {
        expect(
          SeriesRelation.fromWire(entry.key).label,
          entry.value,
          reason: entry.key,
        );
      }
    });

    test('items 是 {relation, work} 而不是裸 WorkSummary', () {
      final series = WorkSeries.fromJson(<String, dynamic>{
        'series_key': '154',
        'series_name': '机动战士高达',
        'items': <dynamic>[
          <String, dynamic>{'relation': 'sequel', 'work': _work('w-1', '续作')},
        ],
      });

      expect(series.items.single.relation, SeriesRelation.sequel);
      expect(series.items.single.work.title, '续作');
      expect(series.seriesKey, '154');
      expect(series.seriesName, '机动战士高达');
    });

    test('series_name 为 null 时保留 key 但名字是 null；坏条目跳过', () {
      final series = WorkSeries.fromJson(<String, dynamic>{
        'series_key': '4281',
        'series_name': null,
        'items': <dynamic>[
          <String, dynamic>{'relation': 'same_series'}, // 缺 work
          <String, dynamic>{
            'relation': 'same_series',
            'work': _work('w-2', '好的那张'),
          },
        ],
      });

      expect(series.seriesName, isNull);
      expect(series.seriesKey, '4281');
      expect(series.items, hasLength(1));
      expect(series.items.single.work.workId, 'w-2');
    });
  });

  group('区块', () {
    testWidgets('渲染系列名、关系标签，当前作品标「当前在看」', (tester) async {
      await tester.pumpWidget(
        _host(
          const _FakeSeriesSource(
            WorkSeries(
              seriesKey: '154',
              seriesName: '机动战士高达',
              items: <WorkSeriesItem>[
                WorkSeriesItem(
                  relation: SeriesRelation.prequel,
                  work: WorkSummary(
                    workId: 'w-0',
                    workType: WorkType.anime,
                    title: '前一部',
                    releaseYear: 1979,
                  ),
                ),
                WorkSeriesItem(
                  relation: SeriesRelation.sameSeries,
                  work: WorkSummary(
                    workId: 'w-1',
                    workType: WorkType.anime,
                    title: '这一部',
                  ),
                ),
              ],
            ),
          ),
          workId: 'w-1',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('机动战士高达'), findsOneWidget);
      expect(find.text('前作'), findsOneWidget);
      expect(find.text('同系列'), findsOneWidget);
      expect(find.text('当前在看'), findsOneWidget);
      expect(find.text('1979'), findsOneWidget);
      expect(find.text('这一部'), findsOneWidget);
    });

    testWidgets('没有系列：整块不渲染，不写「暂无系列」', (tester) async {
      await tester.pumpWidget(
        _host(
          const _FakeSeriesSource(WorkSeries(items: <WorkSeriesItem>[])),
          workId: 'w-1',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('系列作品'), findsNothing);
      expect(find.textContaining('暂无'), findsNothing);
    });

    testWidgets('name 为 null：标题退化成「系列作品」，不显示 key',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const _FakeSeriesSource(
            WorkSeries(
              seriesKey: '4281',
              items: <WorkSeriesItem>[
                WorkSeriesItem(
                  relation: SeriesRelation.sameSeries,
                  work: WorkSummary(
                    workId: 'w-1',
                    workType: WorkType.anime,
                    title: '某部作品',
                  ),
                ),
              ],
            ),
          ),
          workId: 'w-1',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('系列作品'), findsOneWidget);
      expect(find.text('4281'), findsNothing);
    });
  });
}

Widget _host(SeriesDataSource source, {required String workId}) {
  final container = ProviderContainer(
    overrides: [seriesDataSourceProvider.overrideWithValue(source)],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: WorkSeriesSection(workId: workId),
        ),
      ),
    ),
  );
}

class _FakeSeriesSource implements SeriesDataSource {
  const _FakeSeriesSource(this.series);

  final WorkSeries series;

  @override
  Future<SeriesPage> fetchPage(
    String key, {
    int limit = 60,
    int offset = 0,
  }) async =>
      throw UnimplementedError('本测试只走详情页系列区');

  @override
  Future<WorkSeries> fetchForWork(String workId) async => series;
}

Map<String, dynamic> _work(String id, String title) => <String, dynamic>{
  'work_id': id,
  'work_type': 'anime',
  'title': title,
  'cover_url': null,
  'tags': <String>['科幻'],
  'main_rating': null,
  'source': 'shell',
};
