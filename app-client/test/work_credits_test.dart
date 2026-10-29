import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/data/models/work.dart';
import 'package:otaku_app/data/models/work_character.dart';
import 'package:otaku_app/data/models/work_staff.dart';
import 'package:otaku_app/features/detail/work_credits_section.dart';

/// 真后端响应原文（拉取方式见 `docs/w1-real-data-probe.md` 与 Issue #256）。
/// 用真数据而不是手写假对象：测的是「真实形状 → 解析 → 渲染」整条链。
Work loadWork(String name) => Work.fromJson(
  jsonDecode(File('test/fixtures/$name.json').readAsStringSync())
      as Map<String, dynamic>,
);

/// 行是 `Text.rich`，`find.text` 只认 `Text.data`，命中不到 TextSpan，
/// 所以按渲染出来的纯文本找。
Finder richText(String text) => find.byWidgetPredicate(
  (w) =>
      w is Text &&
      w.textSpan != null &&
      w.textSpan!.toPlainText().contains(text),
);

Widget wrap(Widget child) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  ),
);

void main() {
  group('制作人员区块', () {
    testWidgets('93 条：默认只露 6 条，点展开后其余才构建', (tester) async {
      final work = loadWork('real_work_detail_rich');
      expect(work.staff!.length, 93, reason: '真样本，不是构造数据');

      await tester.pumpWidget(wrap(StaffSection(staff: work.staff)));

      expect(find.text('制作人员'), findsOneWidget);
      expect(find.text('展开全部（共 93 条）'), findsOneWidget);

      final seventh = work.staff![6].name;
      expect(
        richText(seventh),
        findsNothing,
        reason: '折叠状态下第 7 条不该被构建——288 条一次铺开会把简介推出屏幕',
      );

      // 尺寸钉子：光看「在树里」不够，零高度的组件也算在树里（PR #259 那种）。
      final box = tester.renderObject<RenderBox>(find.byType(StaffSection));
      expect(box.size.height, greaterThan(0));

      await tester.tap(find.text('展开全部（共 93 条）'));
      await tester.pumpAndSettle();

      expect(richText(seventh), findsOneWidget);
      expect(find.text('收起'), findsOneWidget);
    });

    testWidgets('null 与 [] 都不渲染：不留标题、不留「暂无」、不留空白', (tester) async {
      for (final staff in <List<WorkStaff>?>[null, <WorkStaff>[]]) {
        await tester.pumpWidget(wrap(StaffSection(staff: staff)));

        expect(find.text('制作人员'), findsNothing, reason: 'staff=$staff');
        expect(
          find.text('暂无'),
          findsNothing,
          reason: '动画里三分之二的作品没有 Staff，满屏「暂无」是噪音',
        );

        final box = tester.renderObject<RenderBox>(find.byType(StaffSection));
        expect(box.size, Size.zero, reason: '空态必须是零高度，不能占一段空白');
      }
    });

    testWidgets('不到 6 条时不给展开按钮', (tester) async {
      await tester.pumpWidget(
        wrap(
          StaffSection(
            staff: const [
              WorkStaff(role: '导演', name: '宫崎骏'),
              WorkStaff(role: '音乐', name: '久石让'),
            ],
          ),
        ),
      );
      expect(find.textContaining('展开全部'), findsNothing);
      expect(richText('宫崎骏'), findsOneWidget);
    });

    testWidgets('人名不可点击：人物页属 B2，本期不做跳转', (tester) async {
      final work = loadWork('real_work_detail_rich');
      await tester.pumpWidget(wrap(StaffSection(staff: work.staff)));

      final name = work.staff!.first.name;
      expect(richText(name), findsOneWidget);
      expect(
        find.ancestor(of: richText(name), matching: find.byType(InkWell)),
        findsNothing,
        reason: 'Staff 侧 person_id 实测 0% 有值，做了跳转是跳到不存在的页面',
      );
      expect(
        find.ancestor(
          of: richText(name),
          matching: find.byType(GestureDetector),
        ),
        findsNothing,
      );
    });
  });

  group('角色与声优区块', () {
    testWidgets('12 条：同样折叠，且行内是「角色 · 声优」', (tester) async {
      final work = loadWork('real_work_detail_rich');
      expect(work.characters!.length, 12);

      await tester.pumpWidget(
        wrap(CharacterSection(characters: work.characters)),
      );

      expect(find.text('角色与声优'), findsOneWidget);
      expect(find.text('展开全部（共 12 条）'), findsOneWidget);

      final c = work.characters!.first;
      expect(richText(c.actor), findsOneWidget, reason: '声优名要显示出来');
    });

    testWidgets('character_type 有值也不显示：84% 为空，显示就是编说法', (tester) async {
      await tester.pumpWidget(
        wrap(
          CharacterSection(
            characters: const [
              WorkCharacter(
                name: '猫猫',
                actor: '悠木碧',
                characterType: '主角',
                personId: '5076',
              ),
            ],
          ),
        ),
      );
      expect(richText('猫猫'), findsOneWidget);
      expect(
        find.textContaining('主角'),
        findsNothing,
        reason: '按类型分组会撑出一个巨大的「未知」桶，所以干脆不显示',
      );
      expect(find.textContaining('未知'), findsNothing);
    });

    testWidgets('person_id 有值也不做跳转：人物页落地前一律不可点', (tester) async {
      await tester.pumpWidget(
        wrap(
          CharacterSection(
            characters: const [
              WorkCharacter(name: '猫猫', actor: '悠木碧', personId: '5076'),
            ],
          ),
        ),
      );
      // 这一侧 person_id 实测 100% 有值，是最容易顺手做成可点击的地方——钉住。
      expect(
        find.ancestor(of: richText('猫猫'), matching: find.byType(InkWell)),
        findsNothing,
      );
    });
  });

  group('元信息行', () {
    testWidgets('别名与制作公司渲染成一行，缺失时整行不出现', (tester) async {
      await tester.pumpWidget(
        wrap(
          const Column(
            children: [
              MetaLine(label: '又名', value: '药师少女的独语 / The Apothecary Diaries'),
              MetaLine(label: '制作公司', value: 'TOHO animation STUDIO×OLM'),
            ],
          ),
        ),
      );
      expect(richText('又名'), findsOneWidget);
      expect(richText('制作公司'), findsOneWidget);
    });
  });

  testWidgets('真数据整块渲染不抛异常（93 条 staff + 12 条 characters）', (tester) async {
    final work = loadWork('real_work_detail_rich');
    await tester.pumpWidget(
      wrap(
        Column(
          children: [
            StaffSection(staff: work.staff),
            CharacterSection(characters: work.characters),
          ],
        ),
      ),
    );
    expect(
      tester.takeException(),
      isNull,
      reason: 'render overflow 会以异常抛出——真数据条数超出预期时就是这条先红',
    );
  });

  testWidgets('没有演职员的真作品：两块都不渲染，页面不报错', (tester) async {
    final work = loadWork('real_work_detail_no_credits');
    expect(work.staff, isNull);
    expect(work.characters, isNull);

    await tester.pumpWidget(
      wrap(
        Column(
          children: [
            StaffSection(staff: work.staff),
            CharacterSection(characters: work.characters),
          ],
        ),
      ),
    );
    expect(find.text('制作人员'), findsNothing);
    expect(find.text('角色与声优'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
