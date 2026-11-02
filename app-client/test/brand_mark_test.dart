import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/core/config/app_config.dart';
import 'package:otaku_app/shared/widgets/brand_mark.dart';

/// 品牌标识。
///
/// 这组用例的重点不是「画得好不好看」，而是**站名只有一个来源**：
/// 换站只改 `site.conf` 的 `APP_NAME`，徽标上的字、页面上的名字、关于页的署名
/// 必须一起跟着变。以前是四个页面各写一遍字面量「Otaku」，
/// 换站后主体 UI 还写着上一家的名字（#366）。
void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

  testWidgets('默认显示配置里的站名，徽标取首字', (tester) async {
    await tester.pumpWidget(wrap(const BrandMark()));

    expect(find.text(AppConfig.appName), findsOneWidget);
    expect(find.text('O'), findsOneWidget);
  });

  testWidgets('站名换掉时徽标首字跟着换（不是写死的 O）', (tester) async {
    await tester.pumpWidget(wrap(const BrandMark(name: 'Acgn 站')));

    expect(find.text('Acgn 站'), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('O'), findsNothing);
  });

  testWidgets('副标题可选，不传就不占位', (tester) async {
    await tester.pumpWidget(wrap(const BrandMark()));
    expect(find.text('11 月 2 日 · 周一'), findsNothing);

    await tester.pumpWidget(wrap(const BrandMark(subtitle: '11 月 2 日 · 周一')));
    expect(find.text('11 月 2 日 · 周一'), findsOneWidget);
  });

  testWidgets('showName=false 时只剩徽标', (tester) async {
    await tester.pumpWidget(wrap(const BrandMark(showName: false)));

    expect(find.text(AppConfig.appName), findsNothing);
    expect(find.text('O'), findsOneWidget);
  });

  testWidgets('署名行（空态/错误态用）带站名', (tester) async {
    await tester.pumpWidget(wrap(const BrandSign()));

    expect(find.text(AppConfig.appName), findsOneWidget);
  });

  testWidgets('站名首字对代理对安全：不会劈出半个字', (tester) async {
    // 直接构造一个非 BMP 字符。用 [0] 取会得到半个代理对（渲染成方块）。
    const name = '\u{1F600}站';
    await tester.pumpWidget(wrap(const BrandMark(name: name)));

    expect(find.text(name), findsOneWidget);
    expect(BrandSign.name6(name), '\u{1F600}');
  });
}
