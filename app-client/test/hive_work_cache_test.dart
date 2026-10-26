import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:otaku_app/core/storage/hive_work_cache.dart';
import 'package:otaku_app/core/storage/work_cache.dart';
import 'package:otaku_app/data/models/related_works.dart';
import 'package:otaku_app/data/models/source_rating.dart';
import 'package:otaku_app/data/models/work.dart';
import 'package:otaku_app/data/models/work_sort.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/work_type.dart';

/// Hive 实现的往返测试。
///
/// 内存实现测过了，但 **Hive 那一层才是线上真正跑的那层**：
/// 它多了一次 JSON 编解码、多了一层 Hive 的存储格式。
/// 这一组测试专门盯这两道转换会不会把字段弄丢——
/// 字段丢了不会报错，只会让离线时看到的数据悄悄缺一块。
void main() {
  late Directory tempDir;
  late Box<String> box;
  late HiveWorkCache cache;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('otaku_hive_test');
    Hive.init(tempDir.path);
  });

  setUp(() async {
    box = await Hive.openBox<String>('test_box');
    cache = HiveWorkCache(box);
  });

  tearDown(() async {
    await box.clear();
    await box.close();
  });

  tearDownAll(() async {
    await Hive.deleteBoxFromDisk('test_box');
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('列表页往返', () {
    test('写进去再读出来，字段一个不少', () async {
      const items = [
        WorkSummary(
          workId: 'W-1',
          workType: WorkType.anime,
          title: '测试作品',
          releaseYear: 2021,
          coverUrl: 'https://api.example.com/covers/W-1',
          tags: ['科幻', '机战'],
          mainRating: SourceRating(value: 8.5, scale: '0-10', source: 'otaku_site'),
        ),
        WorkSummary(
          workId: 'W-2',
          workType: WorkType.game,
          title: '没有年份没有评分的作品',
        ),
      ];

      const key = ListCacheKey(
        type: WorkType.anime,
        query: '测试',
        sort: WorkSort.rating,
        page: 2,
      );
      await cache.writeList(
        key,
        const CachedListPage(
          items: items,
          total: 137,
          page: 2,
          pageSize: 50,
          totalPages: 3,
        ),
      );

      final read = await cache.readList(key);
      expect(read, isNotNull);
      expect(read!.value.items.length, 2);

      final first = read.value.items[0];
      expect(first.workId, 'W-1');
      expect(first.workType, WorkType.anime);
      expect(first.title, '测试作品');
      expect(first.releaseYear, 2021);
      expect(first.coverUrl, 'https://api.example.com/covers/W-1');
      expect(first.tags, ['科幻', '机战']);
      expect(first.mainRating?.value, 8.5);
      expect(first.mainRating?.scale, '0-10');
      expect(first.mainRating?.source, 'otaku_site');

      // 可空字段必须还是「没有」，不能被变成 0 / 空串。
      final second = read.value.items[1];
      expect(second.releaseYear, isNull);
      expect(second.coverUrl, isNull);
      expect(second.tags, isNull);
      expect(second.mainRating, isNull);

      // 分页元信息不能丢——丢了翻页条会算错。
      expect(read.value.total, 137);
      expect(read.value.page, 2);
      expect(read.value.pageSize, 50);
      expect(read.value.totalPages, 3);
    });

    test('读一个没写过的键返回 null', () async {
      const key = ListCacheKey(
        type: null,
        query: '',
        sort: WorkSort.id,
        page: 1,
      );
      expect(await cache.readList(key), isNull);
    });

    test('不同键互不干扰', () async {
      const keyA = ListCacheKey(
        type: WorkType.anime,
        query: '甲',
        sort: WorkSort.id,
        page: 1,
      );
      const keyB = ListCacheKey(
        type: WorkType.game,
        query: '乙',
        sort: WorkSort.id,
        page: 1,
      );

      await cache.writeList(
        keyA,
        const CachedListPage(
          items: [
            WorkSummary(workId: 'A', workType: WorkType.anime, title: '甲'),
          ],
          total: 1,
          page: 1,
          pageSize: 50,
          totalPages: 1,
        ),
      );

      expect(await cache.readList(keyB), isNull);
      expect((await cache.readList(keyA))!.value.items.first.title, '甲');
    });
  });

  group('详情往返', () {
    test('写进去再读出来，12 个字段一个不少', () async {
      const work = Work(
        workId: 'W-9',
        workType: WorkType.novel,
        title: '有全部字段的作品',
        summary: '这是简介。\n第二段。',
        releaseYear: 1999,
        coverUrl: 'https://api.example.com/covers/W-9',
        tags: ['悬疑'],
        mainRating: SourceRating(value: 9.0, scale: '0-10', source: 'otaku_site'),
        source: 'otaku_site',
        sourceId: '12345',
        sourceUrl: 'https://example.com/work/12345',
        updatedAt: null,
      );

      const key = DetailCacheKey('W-9');
      await cache.writeDetail(key, work);

      final read = await cache.readDetail(key);
      expect(read, isNotNull);
      final value = read!.value;

      expect(value.workId, 'W-9');
      expect(value.workType, WorkType.novel);
      expect(value.title, '有全部字段的作品');
      expect(value.summary, '这是简介。\n第二段。');
      expect(value.releaseYear, 1999);
      expect(value.coverUrl, 'https://api.example.com/covers/W-9');
      expect(value.tags, ['悬疑']);
      expect(value.mainRating?.value, 9.0);
      expect(value.source, 'otaku_site');
      expect(value.sourceId, '12345');
      expect(value.sourceUrl, 'https://example.com/work/12345');
    });

    test('updatedAt 的时间戳能往返', () async {
      final when = DateTime.utc(2026, 3, 15, 8, 30);
      final work = Work(
        workId: 'W-10',
        workType: WorkType.comic,
        title: '有时间戳',
        updatedAt: when,
      );

      const key = DetailCacheKey('W-10');
      await cache.writeDetail(key, work);

      final read = await cache.readDetail(key);
      expect(read!.value.updatedAt, when);
    });

    test('缓存损坏时读出 null，而不是抛异常', () async {
      const key = DetailCacheKey('W-broken');
      // 手工塞一段坏 JSON，模拟文件损坏。
      await box.put(key.storageKey, '{这不是合法 JSON');

      expect(await cache.readDetail(key), isNull);
    });
  });

  group('推荐往返', () {
    test('basis_tags 与 items 都保得住', () async {
      const related = RelatedWorks(
        basisTags: ['科幻', '机战'],
        items: [
          WorkSummary(workId: 'R-1', workType: WorkType.anime, title: '相关作品'),
        ],
      );

      const key = RelatedCacheKey('W-1');
      await cache.writeRelated(key, related);

      final read = await cache.readRelated(key);
      expect(read, isNotNull);
      expect(read!.value.basisTags, ['科幻', '机战']);
      expect(read.value.items.first.title, '相关作品');
    });
  });

  group('时间戳', () {
    test('每条缓存都带写入时刻', () async {
      final before = DateTime.now();
      const key = DetailCacheKey('W-ts');
      await cache.writeDetail(
        key,
        const Work(workId: 'W-ts', workType: WorkType.anime, title: 'x'),
      );

      final read = await cache.readDetail(key);
      expect(read!.cachedAt.isBefore(before), isFalse);
      expect(read.cachedAt.difference(before).inMinutes.abs(), lessThan(5));
    });
  });

  group('清空', () {
    test('clear 之后所有缓存都没了', () async {
      const detailKey = DetailCacheKey('W-1');
      const listKey = ListCacheKey(
        type: null,
        query: '',
        sort: WorkSort.id,
        page: 1,
      );

      await cache.writeDetail(
        detailKey,
        const Work(workId: 'W-1', workType: WorkType.anime, title: 'x'),
      );
      await cache.writeList(
        listKey,
        const CachedListPage(
          items: [],
          total: 0,
          page: 1,
          pageSize: 50,
          totalPages: 0,
        ),
      );

      await cache.clear();

      expect(await cache.readDetail(detailKey), isNull);
      expect(await cache.readList(listKey), isNull);
    });
  });

  group('容量上限', () {
    test('超过条目上限：淘汰最旧的，刚写入的留下', () async {
      final small = HiveWorkCache(box, maxEntries: 5, maxBytes: 1 << 20);

      // 种 5 条旧记录，写入时刻依次递增（seed-0 最旧）。
      for (var i = 0; i < 5; i++) {
        await box.put('seed-$i', _envelope(DateTime.utc(2026, 1, 1, 0, i)));
      }

      await small.writeDetail(
        const DetailCacheKey('new'),
        const Work(workId: 'new', workType: WorkType.anime, title: '刚看完的'),
      );

      // 6 条超过上限 5 → 淘汰到低水位 4 条（5 × 0.8）。
      expect(box.length, 4);
      expect(box.get('seed-0'), isNull);
      expect(box.get('seed-1'), isNull);
      expect(await small.readDetail(const DetailCacheKey('new')), isNotNull);
    });

    test('被淘汰的键读出来就是没有缓存，而不是报错', () async {
      final small = HiveWorkCache(box, maxEntries: 2, maxBytes: 1 << 20);
      for (var i = 0; i < 3; i++) {
        await box.put('old-$i', _envelope(DateTime.utc(2026, 1, 1, 0, i)));
      }

      await small.writeDetail(
        const DetailCacheKey('fresh'),
        const Work(workId: 'fresh', workType: WorkType.anime, title: 'x'),
      );

      final evicted = 'old-0';
      expect(box.get(evicted), isNull);
      expect(await small.readDetail(const DetailCacheKey('old-0')), isNull);
    });

    test('刚写进来的大条目不会把自己挤掉', () async {
      // 字节上限压到 2KB，再写一条 3KB 的详情。
      final small = HiveWorkCache(box, maxEntries: 100, maxBytes: 2000);
      await box.put('older', _envelope(DateTime.utc(2026, 1, 1)));

      await small.writeDetail(
        const DetailCacheKey('big'),
        Work(
          workId: 'big',
          workType: WorkType.anime,
          title: '长' * 4000,
        ),
      );

      // 旧条目被淘汰，新条目即使自身超限也保留。
      expect(box.get('older'), isNull);
      expect(await small.readDetail(const DetailCacheKey('big')), isNotNull);
    });

    test('解不开的坏记录在清理时被丢掉', () async {
      await box.put('broken', '{这不是合法 JSON');

      final small = HiveWorkCache(box, maxEntries: 10, maxBytes: 1 << 20);
      await small.enforceLimits();

      expect(box.get('broken'), isNull);
    });

    test('没超上限时一条都不动', () async {
      final small = HiveWorkCache(box, maxEntries: 10, maxBytes: 1 << 20);
      for (var i = 0; i < 3; i++) {
        await box.put('keep-$i', _envelope(DateTime.utc(2026, 1, 1, 0, i)));
      }

      await small.enforceLimits();

      expect(box.length, 3);
    });
  });
}

String _envelope(DateTime at) => jsonEncode({
  'cached_at': at.toUtc().toIso8601String(),
  'payload': <String, dynamic>{'items': <dynamic>[]},
});
