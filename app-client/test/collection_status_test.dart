import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/data/models/collection_entry.dart';

/// 契约的四个取值，一个都不能少。
///
/// 这条测试的直接来源是一次真实故障：后端 #540 加了第 4 态 `dropped`
/// （抛弃），客户端枚举还是三态、`parse` 遇未知值直接抛，于是
/// `GET /api/me/collections` 里只要有一条「抛弃」，整页收藏就解析失败。
///
/// 所以这里钉的不是「多一个枚举值」这种实现细节，而是
/// **「契约允许的每个取值都必须能解析」**——服务端扩取值时，这条会红。
void main() {
  group('CollectionStatus 解析', () {
    test('契约里的四个取值全部可解析', () {
      expect(CollectionStatus.parse('want'), CollectionStatus.want);
      expect(CollectionStatus.parse('watching'), CollectionStatus.watching);
      expect(CollectionStatus.parse('watched'), CollectionStatus.watched);
      expect(CollectionStatus.parse('dropped'), CollectionStatus.dropped);
    });

    test('四个取值互不重复，界面文案都不空', () {
      final values = CollectionStatus.values.map((s) => s.value).toSet();
      expect(values, hasLength(CollectionStatus.values.length));
      for (final status in CollectionStatus.values) {
        expect(status.label, isNotEmpty, reason: '${status.value} 缺界面文案');
      }
    });

    test('抛弃是独立状态，不能和「未设状态」混为一谈', () {
      // null = 已收藏但没分类；dropped = 明确不看。画像里前者 +2.0、后者 -2.0，
      // 客户端如果把 dropped 当成 null 展示，用户看不出自己标过「抛弃」。
      expect(CollectionStatus.dropped, isNotNull);
      expect(CollectionStatus.dropped.label, '抛弃');
    });

    test('脏数据仍然抛——不静默降级成「未设状态」', () {
      // 这条是**故意**保留的严格性：契约保证服务端只会下发这四个值，
      // 解析到别的东西说明两端不同步，应当炸出来而不是悄悄吞掉。
      expect(() => CollectionStatus.parse('unknown'), throwsFormatException);
      expect(() => CollectionStatus.parse(''), throwsFormatException);
    });
  });

  group('CollectionEntry 解析', () {
    Map<String, dynamic> json(String? status) => <String, dynamic>{
      'work_id': 'W-1',
      'work_type': 'anime',
      'title': '某部作品',
      'cover_url': null,
      'status': status,
      'updated_at': '2026-11-09T01:00:00Z',
    };

    test('status=dropped 的条目能解析（不再炸整页）', () {
      final entry = CollectionEntry.fromJson(json('dropped'));
      expect(entry.status, CollectionStatus.dropped);
      expect(entry.workId, 'W-1');
    });

    test('status=null 与 dropped 区分开', () {
      expect(CollectionEntry.fromJson(json(null)).status, isNull);
      expect(CollectionEntry.fromJson(json('dropped')).status, isNotNull);
    });

    test('缓存往返保留 dropped', () {
      final entry = CollectionEntry.fromJson(json('dropped'));
      final restored = CollectionEntry.fromJson(entry.toJson());
      expect(restored.status, CollectionStatus.dropped);
    });
  });
}
