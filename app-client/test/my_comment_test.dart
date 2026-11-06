import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:otaku_app/core/platform_info.dart';
import 'package:otaku_app/core/router/route_paths.dart';
import 'package:otaku_app/core/theme/app_theme.dart';
import 'package:otaku_app/data/models/work_summary.dart';
import 'package:otaku_app/data/models/work_type.dart';
import 'package:otaku_app/features/my_comment/my_comment.dart';
import 'package:otaku_app/features/my_comment/my_comment_data_source.dart';
import 'package:otaku_app/features/my_comment/my_comment_mock_data_source.dart';
import 'package:otaku_app/features/my_comment/my_comment_page.dart';
import 'package:otaku_app/shared/widgets/empty_state.dart';
import 'package:otaku_app/shared/widgets/error_state.dart';

import 'support/test_overrides.dart';

/// #449「我的评论」客户端：本轮按「**有这个功能但不用**」落地，所以这里只钉
/// 「功能本身是完整可用的」——四态、三种状态都显示、作品不可见不丢行——
/// 以及「默认数据源是 mock、不发真请求」。不验入口可点（它本就不可点）。
class _FakeMyComments implements MyCommentDataSource {
  _FakeMyComments({this.items = const [], this.fail = false});

  final List<MyComment> items;
  final bool fail;
  int calls = 0;

  @override
  Future<List<MyComment>> fetchAll({required String userId}) async {
    calls++;
    if (fail) throw StateError('boom');
    return items;
  }
}

List<MyComment> _items() => [
  MyComment(
    commentId: 'C-1',
    workId: 'W-1',
    body: '第一条正文',
    status: MyCommentStatus.published,
    createdAt: DateTime.utc(2026, 11, 5, 12, 20),
    work: const WorkSummary(
      workId: 'W-1',
      workType: WorkType.anime,
      title: '街角魔族 第二季',
    ),
  ),
  MyComment(
    commentId: 'C-2',
    workId: 'W-2',
    body: '第二条正文',
    status: MyCommentStatus.pending,
    createdAt: DateTime.utc(2026, 11, 4, 3, 8),
    editedAt: DateTime.utc(2026, 11, 4, 3, 25),
    work: const WorkSummary(
      workId: 'W-2',
      workType: WorkType.comic,
      title: '日常的归还',
    ),
  ),
  // 作品不可见 + 回复 + 被隐藏：最容易「整行被丢掉」的一条。
  MyComment(
    commentId: 'C-3',
    workId: 'W-3',
    body: '第三条正文',
    status: MyCommentStatus.hidden,
    createdAt: DateTime.utc(2026, 11, 3, 9, 41),
    parentId: 'C-1',
  ),
];

void main() {
  Future<void> pumpComments(
    WidgetTester tester, {
    required MyCommentDataSource source,
    bool signedIn = true,
  }) async {
    PlatformInfo.desktopOverride = false;
    addTearDown(PlatformInfo.resetOverride);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final router = GoRouter(
      initialLocation: RoutePaths.myComment,
      routes: [
        GoRoute(
          path: RoutePaths.myComment,
          builder: (_, _) => const MyCommentPage(),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...authOverrides(token: signedIn ? signedInToken : null),
          myCommentDataSourceProvider.overrideWithValue(source),
        ],
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('三种状态都显示，作品不可见的评论仍渲染正文', (tester) async {
    await pumpComments(tester, source: _FakeMyComments(items: _items()));

    expect(find.text('第一条正文'), findsOneWidget);
    expect(find.text('第二条正文'), findsOneWidget);
    expect(find.text('第三条正文'), findsOneWidget);
    expect(find.text('审核中'), findsOneWidget);
    expect(find.text('已隐藏'), findsOneWidget);
    expect(find.text('作品不可见'), findsOneWidget);
    expect(find.textContaining('回复'), findsOneWidget);
    expect(find.textContaining('已编辑'), findsOneWidget);
  });

  testWidgets('空列表给空态，不假装「一条都没有」以外的东西', (tester) async {
    await pumpComments(tester, source: _FakeMyComments());

    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('还没有发过评论'), findsOneWidget);
  });

  testWidgets('失败给错误态 + 重试，点击后重新拉取', (tester) async {
    final source = _FakeMyComments(fail: true);
    await pumpComments(tester, source: source);

    expect(find.byType(ErrorState), findsOneWidget);
    expect(source.calls, 1);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(source.calls, 2);
  });

  testWidgets('未登录给登录引导，且一次都不请求列表', (tester) async {
    final source = _FakeMyComments(items: _items());
    await pumpComments(tester, source: source, signedIn: false);

    expect(find.text('登录后查看我的评论'), findsOneWidget);
    expect(find.text('第一条正文'), findsNothing);
    expect(source.calls, 0);
  });

  test('默认数据源是 mock，不发真请求；路由挂在 /me 下但没有入口 push', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      container.read(myCommentDataSourceProvider),
      isA<MyCommentMockDataSource>(),
    );
    expect(RoutePaths.myComment, '/me/comments');
  });

  test('fromJson 按契约解析；work 缺字段退化成占位而不是整页崩', () {
    final parsed = MyComment.fromJson({
      'comment_id': 'C-9',
      'work_id': 'W-9',
      'body': '正文',
      'status': 'pending',
      'created_at': '2026-11-05T12:20:00Z',
      'edited_at': null,
      'parent_id': null,
      // 缺 title：WorkSummary.fromJson 会抛 FormatException。
      'work': {'work_id': 'W-9'},
    });

    expect(parsed.status, MyCommentStatus.pending);
    expect(parsed.createdAt, isNotNull);
    expect(parsed.isReply, isFalse);
    expect(parsed.work, isNull);

    final unknown = MyComment.fromJson({
      'comment_id': 'C-10',
      'work_id': 'W-10',
      'body': '正文',
      'status': 'archived',
      'work': null,
    });
    expect(unknown.status, MyCommentStatus.unknown);
    expect(unknown.createdAt, isNull);
    expect(unknown.toJson()['work_id'], 'W-10');
  });
}
