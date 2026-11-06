import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/desktop_nav_shell.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/error_state.dart';
import '../../shared/widgets/skeleton_list.dart';
import '../auth/auth_controller.dart';
import 'my_comment.dart';
import 'my_comment_controller.dart';

/// 「我的评论」列表（#449 的客户端侧）。
///
/// 本轮按「**有这个功能但不用**」：路由已注册、页面四态与数据层都完整，
/// 但个人空间里的入口标「未开放」且不可点，数据源也只给 mock、不发真请求。
/// 后端 `GET /api/me/comments` 已上线，所以这不是等待接口的占位壳。
///
/// 口径照 #449 拍板：`published` / `pending` / `hidden` **都要显示**——被隐藏的
/// 评论直接消失，用户会以为「我明明发过」；`deleted` 后端本就不返回。
/// 作品后来不可见时 `work` 为 null，评论正文照常渲染，只把作品名换成占位。
class MyCommentPage extends ConsumerWidget {
  const MyCommentPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(myCommentControllerProvider);
    final signedIn = ref.watch(
      authControllerProvider.select((state) => state.isSignedIn),
    );

    return DesktopNavShell(
      child: Scaffold(
        appBar: AppBar(title: const Text('我的评论')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppLayout.listMaxWidth),
            child: _buildBody(context, ref, value, signedIn),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<MyComment>> value,
    bool signedIn,
  ) {
    // 未登录放在四态之前：controller 会短路返回空列表，不先拦就会显示
    // 「还没有发过评论」——那是谎话，抓不到 ≠ 没有。
    if (!signedIn) {
      return EmptyState(
        icon: Icons.lock_outline_rounded,
        title: '登录后查看我的评论',
        message: '评论跟着账号走，登录后能看到自己发过的评论与回复。',
        action: FilledButton.tonal(
          onPressed: () => context.push(RoutePaths.login),
          child: const Text('去登录'),
        ),
      );
    }

    final items = value.value ?? const <MyComment>[];

    // 错误优先，但不能只看 `hasValue`：Riverpod 3 的失败可能**带着上一次的旧值**。
    // 这里账号态先给空、再加载出用户，build 第一次返回的空列表就成了旧值，
    // 请求失败时若按 `hasError && !hasValue` 判定，失败会被空态盖住。
    // 有可展示的旧数据时仍保留列表——与全站「刷新失败不闪错误页」同一取舍。
    final error = value.error;
    if (error != null && items.isEmpty) {
      return ErrorState(
        error: ApiException.fromAny(error),
        onRetry: () =>
            ref.read(myCommentControllerProvider.notifier).refresh(),
      );
    }

    if (value.isLoading && !value.hasValue) return const SkeletonList();

    if (items.isEmpty) {
      return EmptyState(
        icon: Icons.chat_bubble_outline_rounded,
        title: '还没有发过评论',
        message: '在作品详情页写下第一条评论后，就会出现在这里。',
        action: FilledButton.tonal(
          onPressed: () => context.go(RoutePaths.contents),
          child: const Text('去逛逛作品'),
        ),
      );
    }

    return RefreshIndicator(
      color: AppTheme.brandStrong,
      onRefresh: () =>
          ref.read(myCommentControllerProvider.notifier).refresh(),
      child: ListView.separated(
        key: const PageStorageKey<String>('my-comment-list'),
        padding: const EdgeInsets.fromLTRB(
          AppLayout.pagePadding,
          8,
          AppLayout.pagePadding,
          Space.s6,
        ),
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(height: Space.s2),
        itemBuilder: (context, index) => _CommentCard(comment: items[index]),
      ),
    );
  }
}

class _CommentCard extends StatelessWidget {
  const _CommentCard({required this.comment});

  final MyComment comment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final work = comment.work;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // 作品不可见时没有可跳的详情；不透明 work_id 只透传，不给用户看。
        onTap: work == null
            ? null
            : () => context.push(RoutePaths.workDetail(work.workId)),
        child: Padding(
          padding: const EdgeInsets.all(Space.s4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      work?.title ?? '作品不可见',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: work == null
                            ? theme.colorScheme.onSurfaceVariant
                            : null,
                      ),
                    ),
                  ),
                  // 已发布是默认态，不占一行视觉噪声；只有待审 / 隐藏 /
                  // 未知状态才标出来。
                  if (comment.status != MyCommentStatus.published) ...[
                    const SizedBox(width: Space.s2),
                    _StatusChip(status: comment.status),
                  ],
                ],
              ),
              const SizedBox(height: Space.s2),
              Text(
                comment.body,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: Space.s2),
              Text(
                _meta(comment),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _meta(MyComment comment) {
    final parts = <String>[];
    final createdAt = comment.createdAt;
    if (createdAt != null) parts.add(_formatDate(createdAt));
    if (comment.isReply) parts.add('回复');
    if (comment.editedAt != null) parts.add('已编辑');
    return parts.join(' · ');
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final MyCommentStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        status.label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

/// 只到「日」：评论时间的用途是「什么时候发的」，精确到秒没有意义；
/// 服务端给的是 UTC，统一按本地时区显示。
String _formatDate(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}';
}
