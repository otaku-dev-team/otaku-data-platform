import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/data/models/paged_result.dart';

/// 最小可解析元素：PagedResult 只关心 items 的解析回调，元素形状无所谓。
Map<String, dynamic> _item(int id) => {'work_id': 'W-$id'};

void main() {
  PagedResult<String> parse(Map<String, dynamic> json) => PagedResult.fromJson(
    json,
    (raw) => raw['work_id'] as String,
  );

  group('PagedResult.hidden', () {
    test('后端给了就解析出来', () {
      final result = parse({
        'page': 1,
        'page_size': 20,
        'total': 100,
        'total_pages': 5,
        'items': [_item(1)],
        'hidden': 3,
      });
      expect(result.hidden, 3);
    });

    test('后端没给就是 null，不是 0', () {
      // 资讯 / 收藏这些接口根本没有这个概念：不能补 0，
      // 否则客户端会显示「已隐藏 0 部」这种莫名其妙的话。
      final result = parse({
        'page': 1,
        'page_size': 20,
        'total': 1,
        'total_pages': 1,
        'items': [_item(1)],
      });
      expect(result.hidden, isNull);
    });

    test('明确给了 0 才是「确实一条都没藏」', () {
      final result = parse({
        'page': 1,
        'page_size': 20,
        'total': 1,
        'total_pages': 1,
        'items': [_item(1)],
        'hidden': 0,
      });
      expect(result.hidden, 0);
      expect(result.hidden, isNotNull);
    });

    test('离线缓存往返保留 hidden，缺失时也不写 null', () {
      final withHidden = parse({
        'page': 1,
        'page_size': 20,
        'total': 10,
        'total_pages': 1,
        'items': [_item(1)],
        'hidden': 7,
      });
      final roundTrip = PagedResult<String>.fromJson(
        withHidden.toJson((item) => {'work_id': item}),
        (raw) => raw['work_id'] as String,
      );
      expect(roundTrip.hidden, 7);

      final withoutHidden = parse({
        'page': 1,
        'page_size': 20,
        'total': 10,
        'total_pages': 1,
        'items': [_item(1)],
      });
      expect(
        withoutHidden.toJson((item) => {'work_id': item}).containsKey('hidden'),
        isFalse,
        reason: 'null 不该被写成 null 存进缓存，那会让离线时看起来像「藏了 0 部」',
      );
    });
  });
}
