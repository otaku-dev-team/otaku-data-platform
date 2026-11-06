import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:otaku_app/core/theme/app_theme.dart';
import 'package:otaku_app/data/models/work_character.dart';
import 'package:otaku_app/data/models/work_staff.dart';
import 'package:otaku_app/features/detail/work_credits_section.dart';

/// #455 的入口：`person_id` 非空才可点，空值必须不可点、且**不能把这一行藏掉**。
void main() {
  Future<void> pumpSection(WidgetTester tester, Widget section) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(body: section),
        ),
        GoRoute(
          path: '/persons/:personId',
          builder: (_, state) => Scaffold(
            body: Text('人物页 ${state.pathParameters['personId']}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      MaterialApp.router(
        theme: AppTheme.light(),
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('声优有 person_id：可点、有箭头、点进人物页', (tester) async {
    await pumpSection(
      tester,
      const CharacterSection(
        characters: [
          WorkCharacter(name: '鹿目圆', actor: '悠木碧', personId: 'P-1'),
        ],
      ),
    );

    expect(find.textContaining('悠木碧', findRichText: true), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);

    await tester.tap(find.textContaining('悠木碧', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.text('人物页 P-1'), findsOneWidget);
  });

  testWidgets('声优没有 person_id：仍然是文本，但不可点、无箭头', (tester) async {
    await pumpSection(
      tester,
      const CharacterSection(
        characters: [WorkCharacter(name: '路人甲', actor: '某某')],
      ),
    );

    // 数据缺失不等于这条记录该消失。
    expect(find.textContaining('某某', findRichText: true), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
  });

  testWidgets('Staff 侧 0% 有值：空 id 全不可点，非空才给入口', (tester) async {
    await pumpSection(
      tester,
      const StaffSection(
        staff: [
          WorkStaff(role: '导演', name: '某导演'),
          WorkStaff(role: '脚本', name: '某脚本', personId: 'P-2'),
        ],
      ),
    );

    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);

    await tester.tap(find.textContaining('某脚本', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.text('人物页 P-2'), findsOneWidget);
  });
}
