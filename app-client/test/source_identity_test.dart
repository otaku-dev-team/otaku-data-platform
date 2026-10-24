import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/shared/widgets/cover_image.dart';
import 'package:otaku_app/shared/widgets/source_badge.dart';

/// W1.5 D3：跨源同名作品在列表里必须能被区分。
///
/// 13,261 组同名记录来自不同来源站，靠眼睛分不出来；列表层唯一的抓手就是
/// 2026-10-24 补进 `WorkSummary` 的 `source`。这组用例盯的是三件事：
/// 字段解析（含老缓存缺键）、JSON 往返、以及封面上那枚角标渲染与否。
void main() {
  Map<String, dynamic> payload({String? source, Object? rawSource}) {
    final json = <String, dynamic>{
      'work_id': 'W-8f3a91',
      'work_type': 'anime',
      'title': '街角魔族 2丁目',
      'release_year': 2022,
      'cover_url': null,
      'tags': ['日常'],
      'main_rating': null,
      'source': rawSource ?? source,
    };
    return json;
  }

  test('列表 JSON 带上 source 时解析出来', () {
    final work = WorkSummary.fromJson(payload(source: 'bangumi'));
    expect(work.source, 'bangumi');
  });

  test('旧缓存没有 source 键 —— 不抛，解成 null', () {
    // 这是 D3 上线最容易踩的一处：缓存里躺着字段上线之前的 JSON，
    // 缺键若让它炸，用户升级后打开列表就是一片错误态。
    final work = WorkSummary.fromJson(<String, dynamic>{
      'work_id': 'W-8f3a91',
      'work_type': 'anime',
      'title': '街角魔族 2丁目',
    });
    expect(work.source, isNull);
  });

  test('source 是空串或非字符串 —— 一律归一为 null', () {
    expect(WorkSummary.fromJson(payload(rawSource: '')).source, isNull);
    expect(WorkSummary.fromJson(payload(rawSource: '   ')).source, isNull);
    expect(WorkSummary.fromJson(payload(rawSource: 42)).source, isNull);
  });

  test('toJson / fromJson 往返不丢 source', () {
    final work = WorkSummary.fromJson(payload(source: 'otaku_site'));
    final again = WorkSummary.fromJson(work.toJson());
    expect(again.source, 'otaku_site');
    expect(again.workId, work.workId);
    expect(again.title, work.title);
  });

  testWidgets('封面有 source 时贴一枚角标，两条同名记录靠它分开', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CoverImage(url: null, width: 120, height: 160, source: 'bangumi'),
        ),
      ),
    );

    expect(find.text('bangumi'), findsOneWidget);
  });

  testWidgets('source 为 null 时不渲染任何角标', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CoverImage(url: null, width: 120, height: 160),
        ),
      ),
    );

    expect(find.byType(SourceBadge), findsNothing);
    expect(find.text('bangumi'), findsNothing);
  });
}
