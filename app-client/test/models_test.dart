import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/core/network/api_exception.dart';
import 'package:otaku_app/data/models/paged_result.dart';
import 'package:otaku_app/data/models/source_rating.dart';
import 'package:otaku_app/data/models/work.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/work_type.dart';

Map<String, dynamic> listItem({
  String workId = 'W-8f3a91',
  String title = '街角魔族 2丁目',
  Object? workType = 'anime',
  Object? coverUrl,
  Object? tags,
  Object? rating,
}) {
  return {
    'work_id': workId,
    'work_type': workType,
    'title': title,
    'cover_url': coverUrl,
    'tags': tags,
    'main_rating': rating,
  };
}

void main() {
  group('SourceRating', () {
    test('null 表示没有评分，不能折算成 0 分', () {
      expect(SourceRating.tryParse(null), isNull);
      expect(
        SourceRating.tryParse({'value': null, 'scale': '0-10'}),
        isNull,
      );
    });

    test('value 缺失或非数字时返回 null', () {
      expect(SourceRating.tryParse({'value': '高分'}), isNull);
      expect(SourceRating.tryParse({'scale': '0-10'}), isNull);
      expect(SourceRating.tryParse('7.8'), isNull);
    });

    test('正常解析，显示一位小数', () {
      final rating = SourceRating.tryParse({
        'value': 7.8,
        'scale': '0-10',
        'source': 'otaku_site',
      });
      expect(rating, isNotNull);
      expect(rating!.display, '7.8');
      expect(rating.scale, '0-10');
    });

    test('字符串数字与整数都能解析', () {
      expect(SourceRating.tryParse({'value': '8'})!.display, '8.0');
      expect(SourceRating.tryParse({'value': 9})!.display, '9.0');
    });
  });

  group('WorkSummary', () {
    test('列表项只有 6 个字段，多余字段不影响解析', () {
      final json = listItem()..['summary'] = '这不该被列表用到';
      final work = WorkSummary.fromJson(json);
      expect(work.workId, 'W-8f3a91');
      expect(work.title, '街角魔族 2丁目');
      expect(work.workType, WorkType.anime);
    });

    test('tags 的 null 与 [] 都归一为 null', () {
      expect(WorkSummary.fromJson(listItem(tags: null)).tags, isNull);
      expect(WorkSummary.fromJson(listItem(tags: [])).tags, isNull);
      expect(WorkSummary.fromJson(listItem(tags: ['', '  '])).tags, isNull);
      expect(
        WorkSummary.fromJson(listItem(tags: ['日常', '搞笑'])).tags,
        ['日常', '搞笑'],
      );
    });

    test('cover_url 空串视同 null，界面走占位图', () {
      expect(WorkSummary.fromJson(listItem(coverUrl: '')).coverUrl, isNull);
      expect(
        WorkSummary.fromJson(listItem(coverUrl: 'https://api.example.com/covers/W-1')).coverUrl,
        'https://api.example.com/covers/W-1',
      );
    });

    test('未知 work_type 降级为 unknown，不抛异常', () {
      expect(WorkSummary.fromJson(listItem(workType: 'drama')).workType, WorkType.unknown);
      expect(WorkSummary.fromJson(listItem(workType: null)).workType, WorkType.unknown);
    });

    test('缺 work_id 或 title 时抛 FormatException', () {
      expect(
        () => WorkSummary.fromJson(listItem()..remove('work_id')),
        throwsFormatException,
      );
      expect(
        () => WorkSummary.fromJson(listItem(title: '')),
        throwsFormatException,
      );
    });
  });

  group('Work（详情）', () {
    test('summary 为空串视同 null，界面显示"暂无简介"', () {
      final work = Work.fromJson({
        ...listItem(),
        'summary': '   ',
        'source': 'otaku_site',
        'source_id': '476',
        'updated_at': '2026-10-19T15:28:57+00:00',
      });
      expect(work.summary, isNull);
      expect(work.updatedAt, isNotNull);
    });

    test('summary 保留换行，由界面按段落渲染', () {
      final work = Work.fromJson({
        ...listItem(),
        'summary': '第一段\n第二段',
        'source': 'otaku_site',
        'source_id': '476',
      });
      expect(work.summary, '第一段\n第二段');
    });

    test('source 与 source_id 缺失时不崩，只是溯源信息为空', () {
      final work = Work.fromJson(listItem());
      expect(work.source, isEmpty);
      expect(work.sourceId, isEmpty);
      expect(work.updatedAt, isNull);
    });

    test('staff 三态：null / [] / 非空各自保留，缓存往返不互相归并', () {
      // 契约对 staff / characters / studios 都定义了三态（未提供 / 明确没有 / 有）。
      // 界面上前两者可以同样处理，但解析侧不许把 [] 并进 null——
      // 一次离线缓存往返就把「明确没有」抹成「未提供」了。
      final nulled = Work.fromJson({...listItem(), 'staff': null});
      final emptied = Work.fromJson({...listItem(), 'staff': []});
      final filled = Work.fromJson({
        ...listItem(),
        'staff': [
          {'role': '脚本', 'name': '伊藤和典', 'person_id': null},
        ],
      });

      expect(nulled.staff, isNull);
      expect(emptied.staff, isEmpty);
      expect(filled.staff!.single.role, '脚本');
      // 契约写明 Staff 侧 person_id 实测 0% 有值，人物页落地前一律 null。
      expect(filled.staff!.single.personId, isNull);
    });

    test('staff 里混着脏记录：跳过坏条目，不让整部作品解析失败', () {
      final work = Work.fromJson({
        ...listItem(),
        'staff': [
          {'role': '脚本', 'name': '伊藤和典'},
          '不是对象',
          {'role': '音乐'}, // 缺 name
          {'name': '只有人名'}, // 缺 role
          {}, // 全空 → 过滤掉
        ],
      });
      // 一部作品里混几条脏记录不该让整个详情打不开；
      // 只缺一半的条目仍然要显示（来源侧确实有只给人名的记录）。
      expect(work.staff!.length, 3);
    });

    test('288 条 staff 全量解析不截断——折叠是界面的事，不是解析的事', () {
      final work = Work.fromJson({
        ...listItem(),
        'staff': [
          for (var i = 0; i < 288; i++) {'role': '职位$i', 'name': '人$i'},
        ],
      });
      expect(work.staff!.length, 288, reason: '实测单部最多 288 条（柯南）');
    });

    test('character_type 空串归一为 null：界面不显示「未知类型」', () {
      final work = Work.fromJson({
        ...listItem(),
        'characters': [
          {'name': '猫猫', 'actor': '悠木碧', 'character_type': '   '},
          {'name': '壬氏', 'actor': '大塚剛央', 'character_type': '主角'},
        ],
      });
      expect(work.characters!.first.characterType, isNull);
      expect(work.characters!.last.characterType, '主角');
    });

    test('episodes 越界归一为 null：0 与 10001 都不是话数', () {
      int? parse(Object? raw) =>
          Work.fromJson({...listItem(), 'episodes': raw}).episodes;
      expect(parse(12), 12);
      expect(parse('12'), 12, reason: '字符串数字与整数都能解析');
      expect(parse(0), isNull, reason: '0 话是「来源未提供」，不是真的 0');
      expect(parse(10001), isNull);
      expect(parse(null), isNull);
    });

    test('toJson 与 fromJson 对称：富字段与关联数组过一遍缓存不丢', () {
      final work = Work.fromJson({
        ...listItem(),
        'title_original': '新世紀エヴァンゲリオン',
        'aliases': [],
        'media': 'TV',
        'episodes': 26,
        'staff': [],
        'characters': [
          {'name': '猫猫', 'actor': '悠木碧', 'character_type': null, 'person_id': '5076'},
        ],
        'studios': ['J.C.STAFF'],
      });
      final back = Work.fromJson(work.toJson());
      expect(back.titleOriginal, '新世紀エヴァンゲリオン');
      expect(back.aliases, isEmpty);
      expect(back.media, 'TV');
      expect(back.episodes, 26);
      expect(back.staff, isEmpty);
      expect(back.characters!.single.personId, '5076');
      expect(back.studios, ['J.C.STAFF']);
    });
  });

  group('PagedResult', () {
    Map<String, dynamic> page({
      Object? total,
      Object? page,
      Object? pageSize,
      Object? totalPages,
      List<Object?>? items,
    }) {
      return {
        'total': total,
        'page': page,
        'page_size': pageSize,
        'total_pages': totalPages,
        'items': items ?? [listItem()],
      };
    }

    test('hasNext 由 page < total_pages 决定', () {
      final first = PagedResult<WorkSummary>.fromJson(
        page(total: 24, page: 1, pageSize: 20, totalPages: 2),
        WorkSummary.fromJson,
      );
      expect(first.hasNext, isTrue);

      final second = PagedResult<WorkSummary>.fromJson(
        page(total: 24, page: 2, pageSize: 20, totalPages: 2),
        WorkSummary.fromJson,
      );
      expect(second.hasNext, isFalse);
    });

    test('缺 total_pages 时按 total / page_size 推算', () {
      final result = PagedResult<WorkSummary>.fromJson(
        page(total: 41, page: 1, pageSize: 20),
        WorkSummary.fromJson,
      );
      expect(result.totalPages, 3);
      expect(result.hasNext, isTrue);
    });

    test('单条坏数据跳过，不影响整页', () {
      final result = PagedResult<WorkSummary>.fromJson(
        page(
          total: 2,
          page: 1,
          pageSize: 20,
          totalPages: 1,
          items: [
            listItem(workId: 'W-1'),
            listItem(workId: ''),
            listItem(workId: 'W-2'),
          ],
        ),
        WorkSummary.fromJson,
      );
      expect(result.items.map((e) => e.workId), ['W-1', 'W-2']);
    });

    test('items 缺失时按空列表处理', () {
      final result = PagedResult<WorkSummary>.fromJson(
        page(total: 0, page: 1, pageSize: 20, totalPages: 0, items: const []),
        WorkSummary.fromJson,
      );
      expect(result.isEmpty, isTrue);
      expect(result.hasNext, isFalse);
    });
  });

  group('ApiException', () {
    test('解析统一错误信封', () {
      final exception = ApiException.fromResponse(
        Response<dynamic>(
          requestOptions: RequestOptions(path: '/api/works/x'),
          statusCode: 404,
          data: {
            'error': {'code': 'WORK_NOT_FOUND', 'message': '作品不存在'},
          },
        ),
      );
      expect(exception.code, ApiErrorCode.workNotFound);
      expect(exception.isNotFound, isTrue);
      expect(exception.userMessage, '作品不存在');
    });

    test('没有信封时按状态码降级', () {
      final exception = ApiException.fromResponse(
        Response<dynamic>(
          requestOptions: RequestOptions(path: '/api/works'),
          statusCode: 500,
          data: '<html>bad gateway</html>',
        ),
      );
      expect(exception.code, ApiErrorCode.internal);
      expect(exception.userMessage, '服务端出错了，请稍后重试');
    });
  });
}
