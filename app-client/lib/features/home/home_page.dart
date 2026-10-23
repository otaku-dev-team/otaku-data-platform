import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/platform_info.dart';
import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';
import '../../data/models/article.dart';
import '../../data/models/schedule.dart';
import '../../data/models/work_type.dart';
import '../../shared/widgets/account_menu.dart';
import '../../shared/widgets/compact_work_card.dart';
import '../article/article_card.dart';
import '../contents/contents_controller.dart';
import 'home_controller.dart';

/// 首页：把站点首页那四块聚合在一起——分类浏览 / 本日新番 / 高分作品 / 最新资讯。
///
/// 三条设计取舍：
///
/// 1. **四块各自独立取数、各自呈现失败**。首页是落地页，任何一块挂了都不该
///    把整页变成错误态——那等于"因为资讯接口超时，所以作品也看不了"。
///    所以这里没有整页的 [ErrorState]，只有区块内的窄条 + 重试。
/// 2. **每块只放够判断要不要点进去的量**，其余交给「查看全部」。首页不是
///    第二个列表页；四块都无限滚动的话，它就成了四个列表叠在一起。
/// 3. **本日新番自己取一次数**，不复用档期页的 provider（理由见
///    `homeTodayScheduleProvider` 的注释）：那个跟着季度选择走，
///    用户在档期页翻到旧季度后再回首页，会看到"那一季的今天"。
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('首页'),
        actions: [
          // 桌面端没有下拉手势，刷新得有个按钮（与列表页同一处理）。
          if (PlatformInfo.isDesktop)
            IconButton(
              tooltip: '刷新',
              onPressed: () => _refresh(ref),
              icon: const Icon(Icons.refresh_rounded),
            ),
          const AccountMenuButton(),
          const SizedBox(width: 8),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _refresh(ref),
        child: ListView(
          // 内容不足一屏时也要能下拉：否则短屏/大字号下刷新手势失效。
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(top: 12, bottom: 24),
          children: const [
            _TypeBrowseSection(),
            _TodayScheduleSection(),
            _TopRatedSection(),
            _LatestArticlesSection(),
          ],
        ),
      ),
    );
  }

  /// 下拉 / 按钮刷新：三块一起重取。
  ///
  /// 等三块都结束才收起下拉动画，否则动画一收起就被当成"刷完了"。
  /// 但单块失败不能让刷新一直转圈，所以错误在这里被吞掉——
  /// 它已经在各自区块里呈现过一次了。
  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(homeTodayScheduleProvider);
    ref.invalidate(homeTopRatedProvider);
    ref.invalidate(homeLatestArticlesProvider);

    await Future.wait<void>([
      _settle(ref.read(homeTodayScheduleProvider.future)),
      _settle(ref.read(homeTopRatedProvider.future)),
      _settle(ref.read(homeLatestArticlesProvider.future)),
    ]);
  }

  static Future<void> _settle(Future<Object?> future) =>
      future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
}

/// 区块外壳：统一宽度与左右留白。
///
/// 用 [AppLayout.listMaxWidth] 而不是拉满：窗口 1920 宽时一行 20 个字的卡片
/// 会让人以为内容很少。与列表页同一个上限，页面之间切换不会有"宽度跳变"。
class _Section extends StatelessWidget {
  const _Section({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppLayout.listMaxWidth),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppLayout.pagePadding,
          ),
          child: child,
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.onMore});

  final String title;

  /// 为 null 时不给「查看全部」——没有下一页可看的区块不该有个死按钮。
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          if (onMore != null)
            TextButton(
              onPressed: onMore,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('查看全部', style: theme.textTheme.labelMedium),
                  const Icon(Icons.chevron_right_rounded, size: 16),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 区块的四种状态：失败 / 加载中 / 空 / 有内容。
///
/// 判定顺序是 **错误优先于加载中**：Riverpod 3 里带重试的失败态是
/// `AsyncLoading(error: …)`，只判 `isLoading` 会把错误画成骨架屏，
/// 用户看到的是"一直在加载"（这条坑在详情页踩过，见项目记忆）。
class _SectionBody extends StatelessWidget {
  const _SectionBody({
    required this.hasValue,
    required this.isLoading,
    required this.error,
    required this.onRetry,
    required this.isEmpty,
    required this.emptyText,
    required this.skeletonHeight,
    required this.child,
  });

  /// 已经有旧数据时不再打断它：刷新失败就让旧内容继续留着，
  /// 比把它换成一条错误提示更有用。
  final bool hasValue;
  final bool isLoading;
  final Object? error;
  final VoidCallback onRetry;
  final bool isEmpty;
  final String emptyText;
  final double skeletonHeight;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (error != null && !hasValue) {
      return _InlineError(error: error!, onRetry: onRetry);
    }
    if (isLoading && !hasValue) {
      return _SkeletonBlock(height: skeletonHeight);
    }
    if (isEmpty) return _EmptyLine(text: emptyText);
    return child;
  }
}

/// 区块内的失败提示。**不占整页**：一行图标 + 一句原因 + 重试。
class _InlineError extends StatelessWidget {
  const _InlineError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 只有拿到契约里的错误才有面向用户的文案；断言失败之类的
    // 内部异常不该把堆栈甩到首页上。
    final message = error is ApiException
        ? (error as ApiException).userMessage
        : '这部分没加载出来';

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppLayout.cardRadius),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, size: 18, color: scheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

/// 空态：一行灰字。
///
/// 首页的空态**不整块隐藏**：「今天没有排期」是信息，"本日新番"整块消失
/// 只会让人以为页面坏了或者自己在别的地方。要说清楚，而不是不说。
class _EmptyLine extends StatelessWidget {
  const _EmptyLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _SkeletonBlock extends StatelessWidget {
  const _SkeletonBlock({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppLayout.cardRadius),
      ),
    );
  }
}

/// 分类浏览：四个类型入口。
///
/// 点了之后**重置筛选条件**再跳列表（见 `ContentsFilterController.showType`），
/// 否则会带着上次在列表页选的标签/搜索词过去，结果条数对不上首页的承诺。
class _TypeBrowseSection extends ConsumerWidget {
  const _TypeBrowseSection();

  static IconData _iconOf(WorkType type) => switch (type) {
    WorkType.anime => Icons.movie_outlined,
    WorkType.comic => Icons.auto_stories_outlined,
    WorkType.game => Icons.sports_esports_outlined,
    WorkType.novel => Icons.menu_book_outlined,
    WorkType.unknown => Icons.category_outlined,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _Section(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(title: '分类浏览'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final type in WorkType.selectable)
                ActionChip(
                  avatar: Icon(_iconOf(type), size: 16),
                  label: Text(type.label),
                  onPressed: () {
                    ref.read(contentsFilterProvider.notifier).showType(type);
                    context.go(RoutePaths.contents);
                  },
                ),
            ],
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

/// 本日新番：横向一排，点已收录的进详情。
class _TodayScheduleSection extends ConsumerWidget {
  const _TodayScheduleSection();

  /// 单卡的固定高度。横向列表里卡片高度必须一致，否则一行参差不齐；
  /// 跟着字号缩放，避免大字号下标题被裁掉。
  static const double _cardHeight = 104;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final schedule = ref.watch(homeTodayScheduleProvider);
    final group = schedule.value;
    final items = group == null
        ? const <ScheduleEntry>[]
        : group.items.take(HomeLimits.todaySchedule).toList(growable: false);
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final cardHeight = _cardHeight * textScale;

    return _Section(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(
            title: '本日新番',
            onMore: () => context.go(RoutePaths.schedule),
          ),
          _SectionBody(
            hasValue: schedule.hasValue,
            isLoading: schedule.isLoading,
            error: schedule.error,
            onRetry: () => ref.invalidate(homeTodayScheduleProvider),
            isEmpty: items.isEmpty,
            emptyText: '今天没有排期',
            skeletonHeight: cardHeight,
            child: SizedBox(
              height: cardHeight,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                // 桌面端鼠标拖不动横向列表，但滚轮/触控板可以；
                // 给一条可见的滚动条，别让用户以为右边就是全部。
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, index) =>
                    _TodayScheduleCard(entry: items[index]),
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

class _TodayScheduleCard extends StatelessWidget {
  const _TodayScheduleCard({required this.entry});

  final ScheduleEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 放送时间优先，没有就退回备注（备注里常写「10/5周一深夜」这类补偿信息）。
    final time = entry.broadcastTime ?? entry.broadcastNote;

    return SizedBox(
      width: 196,
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppLayout.cardRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppLayout.cardRadius),
          // 未命中本地作品：整卡不可点，并说明原因——不给死链。
          onTap: entry.isLinked
              ? () => context.push(RoutePaths.workDetail(entry.workId!))
              : null,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (time != null)
                  Text(
                    time,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                const SizedBox(height: 4),
                Expanded(
                  child: Text(
                    entry.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  entry.isLinked ? (entry.workType ?? '已收录') : '本站未收录',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 高分作品：横排海报卡。
class _TopRatedSection extends ConsumerWidget {
  const _TopRatedSection();

  /// 卡片宽度。比列表页的最小列宽（150）略窄一点，
  /// 让一屏能露出"右边还有"的半张卡。
  static const double _cardWidth = 148;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final topRated = ref.watch(homeTopRatedProvider);
    final items = topRated.value ?? const [];
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final stripHeight = CompactWorkCard.heightFor(_cardWidth, textScale);

    return _Section(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(
            title: '高分作品',
            onMore: () {
              // 与「分类浏览」同理：先清条件再跳，
              // 否则"按评分看全部"会落到一个还带着标签筛选的列表上。
              ref.read(contentsFilterProvider.notifier).showTopRated();
              context.go(RoutePaths.contents);
            },
          ),
          _SectionBody(
            hasValue: topRated.hasValue,
            isLoading: topRated.isLoading,
            error: topRated.error,
            onRetry: () => ref.invalidate(homeTopRatedProvider),
            isEmpty: items.isEmpty,
            emptyText: '还没有可推荐的作品',
            skeletonHeight: stripHeight,
            child: SizedBox(
              height: stripHeight,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) =>
                    CompactWorkCard(work: items[index], width: _cardWidth),
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

/// 最新资讯：竖排卡片。
class _LatestArticlesSection extends ConsumerWidget {
  const _LatestArticlesSection();

  static const double _skeletonItemHeight = 88;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final articles = ref.watch(homeLatestArticlesProvider);
    final items = articles.value ?? const <ArticleSummary>[];

    return _Section(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(
            title: '最新资讯',
            onMore: () => context.go(RoutePaths.articles),
          ),
          _SectionBody(
            hasValue: articles.hasValue,
            isLoading: articles.isLoading,
            error: articles.error,
            onRetry: () => ref.invalidate(homeLatestArticlesProvider),
            isEmpty: items.isEmpty,
            emptyText: '暂无资讯',
            skeletonHeight:
                _skeletonItemHeight * HomeLimits.latestArticles + 16,
            child: Column(
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  ArticleCard(
                    article: items[i],
                    onTap: () => context.push(
                      RoutePaths.articleDetail(items[i].articleId),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
