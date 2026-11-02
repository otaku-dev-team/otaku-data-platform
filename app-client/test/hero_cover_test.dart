import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/core/router/route_paths.dart';
import 'package:otaku_app/shared/widgets/hero_cover.dart';

/// 封面转场（Hero）。
///
/// 两件事必须钉住：
/// 1. 详情路由带上标签时形状正确、不带时不加查询串（深链接与旧链接不受影响）；
/// 2. 标签为空时**不套 Hero**——否则详情页会凭空多出一个死标签，
///    而 Hero 标签在同一 Navigator 里重复是直接抛异常的那种错。
void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  group('workDetail 路由', () {
    test('不带标签：保持原来的纯路径', () {
      expect(RoutePaths.workDetail('W-abc'), '/works/W-abc');
    });

    test('带标签：拼成 ?hero=', () {
      expect(
        RoutePaths.workDetail('W-abc', heroTag: 'grid-0'),
        '/works/W-abc?hero=grid-0',
      );
    });

    test('标签做 URL 编码：解回来必须一字不差（空格与斜杠不截断查询串）', () {
      final path = RoutePaths.workDetail('W-abc', heroTag: 'home rated/1');
      // 不断言编码后的字面量（`+` 还是 `%20` 是库的实现细节），
      // 断言的是真正重要的事：路由解析回来的标签 == 传进去的标签。
      expect(Uri.parse(path).queryParameters['hero'], 'home rated/1');
    });

    test('空串等于没给', () {
      expect(RoutePaths.workDetail('W-abc', heroTag: ''), '/works/W-abc');
    });
  });

  group('HeroCover', () {
    testWidgets('没有标签时原样渲染，不多一层 Hero', (tester) async {
      await tester.pumpWidget(wrap(const HeroCover(tag: null, child: Text('封面'))));

      expect(find.text('封面'), findsOneWidget);
      expect(find.byType(Hero), findsNothing);
    });

    testWidgets('有标签时套一层 Hero，标签就是传进来的那个', (tester) async {
      await tester.pumpWidget(
        wrap(const HeroCover(tag: 'grid-3', child: Text('封面'))),
      );

      final hero = tester.widget<Hero>(find.byType(Hero));
      expect(hero.tag, 'grid-3');
      expect(find.text('封面'), findsOneWidget);
    });

    testWidgets('同一屏两个不同标签不会互相干扰', (tester) async {
      await tester.pumpWidget(
        wrap(
          const Row(
            children: [
              HeroCover(tag: 'grid-0', child: Text('A')),
              HeroCover(tag: 'grid-1', child: Text('B')),
            ],
          ),
        ),
      );

      expect(find.byType(Hero), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  });
}
