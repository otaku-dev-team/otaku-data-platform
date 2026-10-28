import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/shared/widgets/cover_image.dart';
import 'package:otaku_app/shared/widgets/source_badge.dart';

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

  testWidgets('带来源徽章：放进 Column 也不炸布局', (tester) async {
    // 「横排条把封面直接放进 Column」这条组合是关键：Column 在主轴上给子节点
    // 的是**无界**约束，而徽章层是一个 Stack——Stack 自己不带尺寸，
    // 拿不到有限约束就抛 `A Stack requires bounded constraints`，整张卡片画不出来。
    // 首页「高分作品」在真数据下正是这样整块空白的（假数据没有 source，
    // 不走徽章这一层，所以这条由假数据构成的用例才一直没炸过）。
    await tester.pumpWidget(
      wrap(
        const Column(
          children: [
            CoverImage(url: null, width: 148, height: 222, source: 'bangumi'),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(SourceBadge), findsOneWidget);
    // 补的框必须就是传进来的尺寸，不能让卡片在布局里被拉变形。
    expect(tester.getSize(find.byType(CoverImage)), const Size(148, 222));
  });

  testWidgets('带来源徽章：宽高传 infinity 时仍交给父级约束', (tester) async {
    // 网格那条路（WorkCard）传的是 double.infinity 且一定带首字占位，
    // 外面还套着 AspectRatio：约束由父级给，此时内部若再补一个固定尺寸的框，
    // 会在无界父级下报 "BoxConstraints forces an infinite height"。
    // 所以 infinity 必须原样透传，最终尺寸听父级的（这里 = 200 × 300）。
    await tester.pumpWidget(
      wrap(
        const SizedBox(
          width: 200,
          child: AspectRatio(
            aspectRatio: 2 / 3,
            child: CoverImage(
              url: null,
              width: double.infinity,
              height: double.infinity,
              placeholderLabel: 'A',
              source: 'bangumi',
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(SourceBadge), findsOneWidget);
    expect(tester.getSize(find.byType(CoverImage)), const Size(200, 300));
  });

  // 头图占位和大海报占位是两套画法：斜纹 + 首字在 64×88 上是「有内容但没配图」，
  // 放大到整屏就是一块喧宾夺主的条纹布，首字被边缘裁掉后只剩两根笔画，
  // 看着像渲染错位。下面两条钉住「头图不画字、海报要画字」这条分界。
  testWidgets('头图占位不画首字（放大后笔画会被裁成两条竖线）', (tester) async {
    await tester.pumpWidget(
      wrap(
        CoverImage.errorFallback(
          width: 390,
          height: 200,
          label: '从',
          style: CoverPlaceholderStyle.hero,
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('从'), findsNothing);
  });

  testWidgets('海报占位仍然画首字', (tester) async {
    await tester.pumpWidget(
      wrap(
        CoverImage.errorFallback(
          width: 148,
          height: 222,
          label: '从',
          style: CoverPlaceholderStyle.poster,
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('从'), findsOneWidget);
  });
}
