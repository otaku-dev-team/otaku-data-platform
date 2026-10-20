import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/shared/widgets/cover_image.dart';

/// 契约 6.3：`cover_url` 为 null 时必须给占位图，不能空白、不能破图。
/// bangumi 档案 10001 条全部没有封面，所以要能一眼看出「本来就没有」，
/// 而不是误以为图片加载失败。
void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('无封面：占位图带图标，不出现图片组件', (tester) async {
    await tester.pumpWidget(wrap(const CoverImage(url: null, width: 64, height: 88)));

    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('无封面：空串与 null 同等处理', (tester) async {
    await tester.pumpWidget(wrap(const CoverImage(url: '', width: 64, height: 88)));

    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
  });

  testWidgets('无封面：列表小尺寸不塞文字，详情大尺寸显示「暂无封面」', (tester) async {
    await tester.pumpWidget(wrap(const CoverImage(url: null, width: 64, height: 88)));
    expect(find.text('暂无封面'), findsNothing);

    await tester.pumpWidget(wrap(const CoverImage(url: null, width: 160, height: 218)));
    expect(find.text('暂无封面'), findsOneWidget);
  });
}
