import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/core/theme/app_layout.dart';
import 'package:otaku_app/shared/widgets/desktop_nav_shell.dart';
import 'package:otaku_app/shared/widgets/desktop_shortcuts.dart';

/// flutter-lead-plan §6 的两端差异清单里，能自动验的那几条。
///
/// 不验的：窗口最小尺寸与尺寸记忆（要真实窗口，widget 测试里没有）、
/// 悬停高亮（要真实指针）、凭据存储（要平台通道）。
void main() {
  group('网格列数', () {
    test('宽屏最多 4 列，不会一路涨到 8 列', () {
      final metrics = AppLayout.gridMetrics(2000);
      expect(metrics.columns, 4);
      // 4 列时单卡宽度应该随可用宽度变大，而不是被压窄
      expect(metrics.cardWidth, greaterThan(AppLayout.gridMinCardWidth));
    });

    test('窄屏最少 2 列', () {
      expect(AppLayout.gridMetrics(300).columns, 2);
    });

    test('中间宽度按最小卡宽算，不跳变', () {
      // 900 / 190 = 4.7 → 4 列
      expect(AppLayout.gridMetrics(900).columns, 4);
      // 700 / 190 = 3.68 → 3 列
      expect(AppLayout.gridMetrics(700).columns, 3);
    });
  });

  group('DesktopNavShell', () {
    Widget shellUnder(double width) => MaterialApp(
      home: DesktopNavShell(
        child: Scaffold(body: const Text('内容')),
      ),
    );

    testWidgets('宽窗口显示侧栏，内容区仍在', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(shellUnder(1200));
      await tester.pump();

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.text('内容'), findsOneWidget);
    });

    testWidgets('窄窗口不显示侧栏（手机形态）', (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(shellUnder(420));
      await tester.pump();

      expect(find.byType(NavigationRail), findsNothing);
      expect(find.text('内容'), findsOneWidget);
    });

    testWidgets('侧栏文案不和列表页标题重名', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(shellUnder(1200));
      await tester.pump();

      // 列表页 AppBar 标题是「作品库」、收藏页是「我的收藏」。
      // 侧栏如果用同样的字，`find.text` 会一次命中两个，断言全部失真。
      expect(find.text('作品库'), findsNothing);
      expect(find.text('我的收藏'), findsNothing);
    });
  });

  group('DesktopShortcuts', () {
    testWidgets('Ctrl+R 触发刷新', (tester) async {
      var refreshCount = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopShortcuts(
            onRefresh: () => refreshCount++,
            child: const Scaffold(body: Text('页面')),
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(refreshCount, 1);
    });

    testWidgets('没有 onRefresh 时 Ctrl+R 不报错', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DesktopShortcuts(child: Scaffold(body: Text('详情'))),
        ),
      );
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('按 / 触发 onSearch（聚焦搜索框）', (tester) async {
      var searchCount = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopShortcuts(
            onSearch: () => searchCount++,
            child: const Scaffold(body: Text('页面')),
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.pump();

      expect(searchCount, 1);
    });

    testWidgets('没有 onSearch 时按 / 不报错', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DesktopShortcuts(child: Scaffold(body: Text('详情'))),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('Esc 在可返回时 pop 一层', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const DesktopShortcuts(
                        child: Scaffold(body: Text('详情页')),
                      ),
                    ),
                  ),
                  child: const Text('进详情'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('进详情'));
      await tester.pumpAndSettle();
      expect(find.text('详情页'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.text('详情页'), findsNothing);
    });

    testWidgets('onEscape 返回 true 时不 pop（页面自己消费了 Esc）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => DesktopShortcuts(
                        onEscape: () => true,
                        child: const Scaffold(body: Text('搜索中的页面')),
                      ),
                    ),
                  ),
                  child: const Text('进页面'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('进页面'));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // 页面自己处理了 Esc（例如让搜索框失焦），不该连带把页面弹掉。
      expect(find.text('搜索中的页面'), findsOneWidget);
    });

    testWidgets('onEscape 返回 false 时照常 pop', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => DesktopShortcuts(
                        onEscape: () => false,
                        child: const Scaffold(body: Text('没处理 Esc 的页面')),
                      ),
                    ),
                  ),
                  child: const Text('进页面'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('进页面'));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.text('没处理 Esc 的页面'), findsNothing);
    });
  });
}
