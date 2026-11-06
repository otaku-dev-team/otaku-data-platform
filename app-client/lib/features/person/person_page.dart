import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../core/theme/app_layout.dart';
import '../../core/theme/design_tokens.dart';
import '../../data/models/person_detail.dart';
import '../../shared/widgets/desktop_nav_shell.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/error_state.dart';
import '../../shared/widgets/mobile_nav_bar.dart';
import '../../shared/widgets/skeleton_list.dart';
import '../contents/work_list_tile.dart';
import 'person_controller.dart';

/// 人物详情页（#455，档 B2）。
///
/// 从作品详情页的「制作人员 / 角色与声优」点进来。数据来自
/// `GET /api/persons/{person_id}`，服务端已把「同一部作品的配音与制作」
/// 合并成一条，所以这里**不拆成两个列表**——拆开会变成两张一模一样的作品卡。
/// 两类身份在同一张卡下面分两行写。
///
/// `works` 实测可能一两百条（某声优 193 部），必须用 `ListView.builder`；
/// 一次性铺开会让首帧卡住（#455 评论里 pyxz0 专门提过）。
class PersonPage extends ConsumerWidget {
  const PersonPage({super.key, required this.personId});

  final String personId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(personDetailProvider(personId));
    final detail = async.value;
    final title = detail != null && detail.personName.isNotEmpty
        ? detail.personName
        : '人物';

    return DesktopNavShell(
      child: Scaffold(
        bottomNavigationBar: MobileNavBar.forScaffold(context),
        appBar: AppBar(title: Text(title)),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: AppLayout.listMaxWidth,
            ),
            child: _body(context, ref, async),
          ),
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<PersonDetail> async,
  ) {
    if (async.isLoading && !async.hasValue) return const SkeletonList();

    final error = async.error;
    if (error != null && !async.hasValue) {
      final api = ApiException.fromAny(error);
      // 契约：人物不存在 / id 非法都是 404，且**不给重试**——重试一次还是 404，
      // 只会让用户以为「再点一下就能出来」。
      final missing = api.statusCode == 404;
      return ErrorState(
        error: api,
        title: missing ? '人物不存在' : null,
        onRetry: missing
            ? null
            : () => ref.invalidate(personDetailProvider(personId)),
      );
    }

    final detail = async.value;
    if (detail == null) return const SizedBox.shrink();

    if (!detail.hasWorks) {
      return const EmptyState(
        icon: Icons.person_off_outlined,
        title: '这个人还没有可展示的作品',
        message: '我们库里暂时没有他参与的作品，或者相关作品都已下架。',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppLayout.pagePadding,
        8,
        AppLayout.pagePadding,
        Space.s6,
      ),
      // 首项是头部（名字 + 统计），其余是作品；用 builder 而不是 Column，
      // 一两百条时差别很明显。
      itemCount: detail.works.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return _PersonHeader(detail: detail);
        return _CreditEntry(credit: detail.works[index - 1]);
      },
    );
  }
}

class _PersonHeader extends StatelessWidget {
  const _PersonHeader({required this.detail});

  final PersonDetail detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stats = <String>[
      if (detail.castCount > 0) '配音 ${detail.castCount} 部',
      if (detail.creditCount > 0) '制作 ${detail.creditCount} 部',
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            detail.personName,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (stats.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              stats.join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: Space.s3),
          const Divider(height: 1),
          const SizedBox(height: Space.s2),
        ],
      ),
    );
  }
}

class _CreditEntry extends StatelessWidget {
  const _CreditEntry({required this.credit});

  final PersonCredit credit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          WorkListTile(work: credit.work),
          // 同一部作品只出一张卡，但「配的谁」与「做了什么」是两件事：
          // 混在一行会读成一串没有主语的词，分两行才看得懂。
          if (credit.hasCharacters)
            _CreditLine(label: '配音', values: credit.characters),
          if (credit.hasRoles)
            _CreditLine(label: '制作', values: credit.roles),
        ],
      ),
    );
  }
}

class _CreditLine extends StatelessWidget {
  const _CreditLine({required this.label, required this.values});

  final String label;
  final List<String> values;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label：',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            TextSpan(
              text: values.join('、'),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
