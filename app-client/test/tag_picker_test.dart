import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/data/models/tag_vocabulary.dart';
import 'package:otaku_app/features/contents/tag_picker.dart';
import 'package:otaku_app/features/contents/tag_vocabulary_provider.dart';

/// 标签面板的交互契约：选了才返回、取消返回 null、到上限点不动。
///
/// 这里不测「面板长得好看」，只钉三件会影响筛选结果的事。
void main() {
  const vocabulary = TagVocabulary(
    total: 3,
    items: [
      TagCount(name: '科幻', count: 120),
      TagCount(name: '日常', count: 30),
      TagCount(name: '机战', count: 8),
    ],
  );

  Future<void> pumpPicker(
    WidgetTester tester, {
    required void Function(List<String>?) onResult,
    List<String> selected = const [],
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tagVocabularyProvider.overrideWith((ref) async => vocabulary),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  onResult(await showTagPicker(context, selected: selected));
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('选两个标签再应用：返回这两个', (tester) async {
    List<String>? result;
    await pumpPicker(tester, onResult: (value) => result = value);

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    // 词表项带作品数，用户能判断这个标签是不是常用。
    expect(find.text('科幻 · 120'), findsOneWidget);

    await tester.tap(find.text('科幻 · 120'));
    await tester.tap(find.text('日常 · 30'));
    await tester.pumpAndSettle();

    expect(find.text('已选 2/10'), findsOneWidget);

    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();

    expect(result, ['科幻', '日常']);
  });

  testWidgets('取消返回 null——不能悄悄把已有条件清空', (tester) async {
    List<String>? result;
    await pumpPicker(
      tester,
      onResult: (value) => result = value,
      selected: ['机战'],
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });

  testWidgets('已选满 10 个：未选中的 chip 点不动', (tester) async {
    final many = List<String>.generate(10, (index) => 't$index');
    List<String>? result;
    await pumpPicker(
      tester,
      onResult: (value) => result = value,
      selected: many.sublist(0, 9),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('已选 9/10'), findsOneWidget);

    // 选第 10 个：可以。
    await tester.tap(find.text('科幻 · 120'));
    await tester.pumpAndSettle();
    expect(find.text('已选 10/10'), findsOneWidget);

    // 第 11 个：chip 被禁用，点了没反应，也不该报错。
    await tester.tap(find.text('日常 · 30'));
    await tester.pumpAndSettle();
    expect(find.text('已选 10/10'), findsOneWidget);

    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();

    expect(result, hasLength(10));
    expect(result, isNot(contains('日常')));
  });
}
