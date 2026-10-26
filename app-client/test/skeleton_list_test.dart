import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/shared/widgets/skeleton_list.dart';

/// 骨架屏的语义。
///
/// 读屏用户看不到「灰色方块在呼吸」：在此之前首屏加载这一幕是完全静默的，
/// 容易被当成页面没反应。这里钉住「只报一句加载中」这件事。
void main() {
  testWidgets('骨架屏对读屏只报「加载中」', (tester) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SkeletonList())),
    );
    await tester.pump(const Duration(milliseconds: 50));

    final node = tester.getSemantics(find.byType(SkeletonList));
    expect(node.label, '加载中');

    handle.dispose();
  });
}
