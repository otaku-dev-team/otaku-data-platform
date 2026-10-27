import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/data/datasources/tag_mock_data_source.dart';
import 'package:otaku_app/data/datasources/tag_remote_data_source.dart';
import 'package:otaku_app/data/models/tag_vocabulary.dart';
import 'package:otaku_app/data/models/work_type.dart';

/// 标签词表（`GET /api/tags`）。
///
/// 词表本身不复杂，容易错的是三件事：`total` 的语义（本次条数，不是全库总数）、
/// 排序（count 降序 + 名称升序，否则面板顺序每次刷新都在跳）、
/// 以及空名字要丢掉（点了也筛不出东西）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('解析', () {
    test('items / total / type 都认，空名字被丢掉', () {
      final vocabulary = TagVocabulary.fromJson({
        'type': 'anime',
        'total': 3,
        'items': [
          {'name': '科幻', 'count': 120},
          {'name': '  ', 'count': 9},
          {'name': '日常', 'count': 30},
        ],
      });

      expect(vocabulary.type, 'anime');
      expect(vocabulary.items.map((e) => e.name), ['科幻', '日常']);
      expect(vocabulary.items.first.count, 120);
    });

    test('没有 items 时给空表，不抛', () {
      final vocabulary = TagVocabulary.fromJson({});
      expect(vocabulary.items, isEmpty);
      expect(vocabulary.total, 0);
    });
  });

  group('Mock 词表', () {
    test('按 count 降序、同名升序；type 过滤生效', () async {
      final source = MockTagDataSource(
        bundle: _StubBundle(),
        latency: Duration.zero,
      );

      final all = await source.fetchTags();
      expect(all.items.map((e) => e.name), ['科幻', '日常', '机战']);
      expect(all.items.first.count, 2);

      final animeOnly = await source.fetchTags(type: WorkType.anime);
      expect(animeOnly.items.map((e) => e.name), ['科幻', '日常']);
    });
  });

  group('真接口', () {
    test('type 与 limit 变成查询参数；都省略时不带参数', () async {
      final adapter = _CapturingAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'http://test.local'));
      dio.httpClientAdapter = adapter;
      final source = RemoteTagDataSource(dio);

      await source.fetchTags(type: WorkType.game, limit: 50);
      expect(adapter.lastQuery['type'], 'game');
      expect(adapter.lastQuery['limit'], 50);

      await source.fetchTags();
      expect(adapter.lastQuery.containsKey('type'), isFalse);
      expect(adapter.lastQuery.containsKey('limit'), isFalse);
    });
  });
}

/// 最小目录：三条作品，标签分布用来验 count 与排序。
class _StubBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => ByteData.view(Uint8List(0).buffer);

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    return jsonEncode({
      'items': [
        {
          'work_id': 'W-1',
          'work_type': 'anime',
          'title': 'A',
          'tags': ['科幻', '日常'],
        },
        {
          'work_id': 'W-2',
          'work_type': 'anime',
          'title': 'B',
          'tags': ['科幻'],
        },
        {'work_id': 'W-3', 'work_type': 'game', 'title': 'C', 'tags': ['机战']},
        {'work_id': 'W-4', 'work_type': 'game', 'title': 'D'},
      ],
      'total': 4,
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
      jsonEncode({'items': <dynamic>[], 'total': 0}),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
