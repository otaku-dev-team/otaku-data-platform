import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/core/storage/work_cache.dart';
import 'package:otaku_app/data/datasources/work_mock_data_source.dart';
import 'package:otaku_app/data/datasources/work_remote_data_source.dart';
import 'package:otaku_app/data/models/work_sort.dart';
import 'package:otaku_app/features/contents/contents_controller.dart';

/// 年份筛选（契约 `GET /api/works?year=`）。
///
/// 三处容易漏的地方都在这里钉住：
/// 1. **缓存键**必须带上年份，否则「2022 年的第一页」会覆盖「不限年份的第一页」，
///    离线时看到的条数与在线完全不同；
/// 2. **筛选状态**换别的条件时不能把年份丢掉（以前每个 setter 手抄字段，
///    加一个维度就要改五处）；
/// 3. **真接口**要把 `year` 透传成查询参数，且 null 时不能带空参数。
void main() {
  // Mock 数据源走 rootBundle 读 assets，需要先初始化 binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('缓存键：年份是独立维度', () {
    const withYear = ListCacheKey(
      type: null,
      query: '',
      sort: WorkSort.id,
      page: 1,
      year: 2022,
    );
    const withoutYear = ListCacheKey(
      type: null,
      query: '',
      sort: WorkSort.id,
      page: 1,
    );
    const otherYear = ListCacheKey(
      type: null,
      query: '',
      sort: WorkSort.id,
      page: 1,
      year: 2021,
    );

    test('不同年份的键不相等、存储键也不同', () {
      expect(withYear, isNot(otherYear));
      expect(withYear.storageKey, isNot(otherYear.storageKey));
      expect(withYear, isNot(withoutYear));
      expect(withYear.storageKey, isNot(withoutYear.storageKey));
    });

    test('年份相同的键相等', () {
      const same = ListCacheKey(
        type: null,
        query: '',
        sort: WorkSort.id,
        page: 1,
        year: 2022,
      );
      expect(withYear, same);
      expect(withYear.hashCode, same.hashCode);
    });
  });

  group('筛选状态：年份与其余条件互不覆盖', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
      addTearDown(container.dispose);
    });

    ContentsFilter read() => container.read(contentsFilterProvider);

    test('selectYear 保留类型 / 关键词 / 标签 / 排序', () {
      final notifier = container.read(contentsFilterProvider.notifier);
      notifier.selectType(null);
      notifier.search('魔法');
      notifier.selectTag('奇幻');
      notifier.selectSort(WorkSort.rating);
      notifier.selectYear(2022);

      final filter = read();
      expect(filter.year, 2022);
      expect(filter.query, '魔法');
      expect(filter.tag, '奇幻');
      expect(filter.sort, WorkSort.rating);
    });

    test('换标签/搜索不会把年份丢掉', () {
      final notifier = container.read(contentsFilterProvider.notifier);
      notifier.selectYear(2022);
      notifier.selectTag('奇幻');
      expect(read().year, 2022);

      notifier.search('魔法');
      expect(read().year, 2022);
    });

    test('selectYear(null) 取消年份，其余条件不动', () {
      final notifier = container.read(contentsFilterProvider.notifier);
      notifier.selectTag('奇幻');
      notifier.selectYear(2022);
      notifier.selectYear(null);

      expect(read().year, isNull);
      expect(read().tag, '奇幻');
    });

    test('clearFilters 连年份一起清，但保留排序', () {
      final notifier = container.read(contentsFilterProvider.notifier);
      notifier.selectTag('奇幻');
      notifier.selectYear(2022);
      notifier.selectSort(WorkSort.rating);

      notifier.clearFilters();

      expect(read().tag, isNull);
      expect(read().year, isNull);
      expect(read().sort, WorkSort.rating);
    });

    test('showTag 从详情页进来：只剩标签，年份要清掉', () {
      final notifier = container.read(contentsFilterProvider.notifier);
      notifier.selectYear(2022);
      notifier.showTag('奇幻');

      expect(read().tag, '奇幻');
      expect(read().year, isNull);
    });
  });

  group('Mock 数据源按年份过滤', () {
    test('只留该年份；没年份的条目被排除', () async {
      final source = MockWorkDataSource(
        bundle: _StubBundle(),
        latency: Duration.zero,
      );

      final all = await source.fetchWorks(pageSize: 50);
      expect(all.items, hasLength(3));

      final filtered = await source.fetchWorks(year: 2022, pageSize: 50);
      expect(filtered.items, hasLength(1));
      expect(filtered.items.single.releaseYear, 2022);
      expect(filtered.total, 1);

      // 2020 年一条都没有：空结果，不是报错。
      final none = await source.fetchWorks(year: 2020, pageSize: 50);
      expect(none.items, isEmpty);
      expect(none.total, 0);
    });
  });

  group('真接口：year 变成查询参数', () {
    test('传了年份就带 year，没传就不带', () async {
      final adapter = _CapturingAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'http://test.local'));
      dio.httpClientAdapter = adapter;
      final source = RemoteWorkDataSource(dio);

      await source.fetchWorks(year: 2022);
      expect(adapter.lastQuery['year'], 2022);

      await source.fetchWorks();
      expect(adapter.lastQuery.containsKey('year'), isFalse);
    });
  });
}

/// Mock 数据源要读 assets；这里给一份最小目录，只为验年份过滤。
class _StubBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => ByteData.view(Uint8List(0).buffer);

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    return jsonEncode({
      'items': [
        {'work_id': 'W-1', 'work_type': 'anime', 'title': '二〇二二', 'release_year': 2022},
        {'work_id': 'W-2', 'work_type': 'anime', 'title': '二〇二一', 'release_year': 2021},
        {'work_id': 'W-3', 'work_type': 'anime', 'title': '没有年份'},
      ],
      'total': 3,
      'page': 1,
      'page_size': 50,
      'total_pages': 1,
    });
  }
}

class _CapturingAdapter implements HttpClientAdapter {
  Map<String, dynamic> lastQuery = const {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastQuery = Map<String, dynamic>.from(options.queryParameters);
    return ResponseBody.fromString(
      jsonEncode({
        'items': <dynamic>[],
        'total': 0,
        'page': 1,
        'page_size': 50,
        'total_pages': 0,
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
