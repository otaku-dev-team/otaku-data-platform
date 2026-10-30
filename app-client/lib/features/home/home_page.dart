import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/platform_info.dart';
import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/article.dart';
import '../../data/models/schedule.dart';
import '../../data/models/work_summary.dart';
import '../../data/models/work_type.dart';
import '../../shared/widgets/account_menu.dart';
import '../../shared/widgets/cover_image.dart';
import '../../shared/widgets/compact_work_card.dart';
import '../../shared/widgets/desktop_nav_shell.dart';
import '../../shared/widgets/mobile_nav_bar.dart';
import '../../shared/widgets/desktop_shortcuts.dart';
import '../article/article_card.dart';
import '../contents/catalog_counts.dart';
import '../contents/contents_controller.dart';
import '../recent/recent_views_controller.dart';
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
    // 首页也要套桌面外壳：侧栏是全局导航，落地页少了它，桌面上进来就出不去
    // （外层的 `_buildRail` 已经把「首页」算成第 0 项，这里必须接上）。
    return DesktopNavShell(
      child: DesktopShortcuts(
        onRefresh: () => _refresh(ref),
        child: Scaffold(
          bottomNavigationBar: MobileNavBar.forScaffold(context),
          appBar: AppBar(
            // 标题不再是「首页」两个字：底部导航已经写着首页，AppBar 再写
            // 一遍只是重复；换成品牌行 + 日期，首屏才有落地页的样子。
            toolbarHeight: 66,
            titleSpacing: AppLayout.pagePadding,
            title: const _HomeBrand(),
            actions: [
              // 桌面端没有下拉手势，刷新得有个按钮（与列表页同一处理）。
              if (PlatformInfo.isDesktop)
                IconButton(
                  tooltip: '刷新',
                  onPressed: () => _refresh(ref),
                  icon: const Icon(Icons.refresh_rounded),
                ),
              // 手机上没有侧栏，设置只能从这里进。放在账号入口左边：
              // 账号是「我是谁」，设置是「这个应用怎么表现」，都不是内容。
              IconButton(
                tooltip: '设置',
                onPressed: () => context.push(RoutePaths.settings),
                icon: const Icon(Icons.settings_outlined),
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
              padding: const EdgeInsets.only(top: 4, bottom: 24),
              children: const [
                _SearchEntry(),
                _FeaturedHero(),
                _RecentViewsSection(),
                _TypeBrowseSection(),
                _TodayScheduleSection(),
                _TopRatedSection(),
                _LatestArticlesSection(),
              ],
            ),
          ),
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

/// 顶部品牌行：应用标识 + 日期，右侧设置与账号由 AppBar actions 提供。
///
/// 参考 banguLite / AFAN 这类追番客户端的首页：顶部不放一个孤零零的页面名，
/// 而是一块带身份感的抬头（标识 + 今天几号）。AppBar 底色已经和页面同色，
/// 这块抬头是首屏唯一「像页头」的东西。
class _HomeBrand extends StatelessWidget {
  const _HomeBrand();

  static const _weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final date = '${now.month} 月 ${now.day} 日 · ${_weekdays[now.weekday - 1]}';

    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            // 品牌蓝 → 站点那抹青，和封面占位、渐变头图同一族色。
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppTheme.brand, AppTheme.accent],
            ),
          ),
          child: const Text(
            'O',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
        ),
        const SizedBox(width: 10),
        // AppBar 里标题的宽度是抢来的（右边还有设置与账号），所以这一列
        // 必须能收缩：不包 Flexible，窄屏上两行文字会把工具条挤出 33px。
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Otaku',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                date,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 首页搜索入口。
///
/// 搜索本身在作品库里（那边有输入框和筛选），这里只做「一眼能看到入口」：
/// 资讯/番剧类 App 的首屏几乎都在顶部放一条搜索框，缺了它首页像一个静态目录。
class _SearchEntry extends StatelessWidget {
  const _SearchEntry();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppLayout.pagePadding,
        8,
        AppLayout.pagePadding,
        2,
      ),
      child: Material(
        color: AppTheme.cardColor(context),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppLayout.cardRadius),
          side: BorderSide(color: AppTheme.borderColor(context), width: 0.5),
        ),
        child: InkWell(
          onTap: () => context.go(RoutePaths.contents),
          child: SizedBox(
            height: 46,
            child: Row(
              children: [
                const SizedBox(width: 14),
                Icon(
                  Icons.search_rounded,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '搜索作品名或标签',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 9,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '去搜索',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
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
  const _SectionHeader({required this.title, this.onMore, this.trailing});

  final String title;

  /// 为 null 时不给「查看全部」——没有下一页可看的区块不该有个死按钮。
  final VoidCallback? onMore;

  /// 标题右侧的附加操作（如「清空」），排在「查看全部」之前。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          // 色条：六个区块标题字号一样、颜色一样，光靠字幕分不出段与段。
          // 一条 3px 的品牌色立柱把每段的起点标出来，比加粗或放大安静。
          Container(
            width: 3,
            height: 15,
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          ?trailing,
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
    required this.emptyIcon,
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
  final IconData emptyIcon;
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
    if (isEmpty) return _EmptyCard(text: emptyText, icon: emptyIcon);
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

/// 空态：一张很轻的小卡（图标 + 一句说明）。
///
/// 首页的空态**不整块隐藏**：「今天没有排期」是信息，"本日新番"整块消失
/// 只会让人以为页面坏了或者自己在别的地方。要说清楚，而不是不说。
///
/// 从「一行灰字」改成卡片：这三个空块（本日新番 / 高分作品 / 最新资讯）
/// 在这版真数据下全都会出现，一行浮在留白里的灰字看着像没加载完；
/// 给个卡片边界，视觉上才是「这里确实没有内容」。
class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.text, required this.icon});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      decoration: BoxDecoration(
        color: AppTheme.cardColor(context),
        borderRadius: BorderRadius.circular(AppLayout.cardRadius),
        border: Border.all(color: AppTheme.borderColor(context), width: 0.5),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
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

/// 最近浏览：本地历史，断网也能看见自己看过什么。
///
/// **空的时候整块不渲染**：首页给新用户看的第一屏不该有一行「最近浏览（空）」。
/// 这与「本日新番」空着也要说一句不同——「今天没有排期」是事实，
/// 而「你还没看过任何作品」对刚装上 App 的人是句废话，只占地方。
class _RecentViewsSection extends ConsumerWidget {
  const _RecentViewsSection();

  /// 比「高分作品」的 148 窄一档：这一块是自己的足迹，不该比推荐更抢眼。
  static const double _cardWidth = 116;

  /// 首页横排露几条。再多也没人横向翻到底——完整列表在「全部」里。
  static const int _previewCount = 10;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(recentViewsProvider);
    if (items.isEmpty) return const SizedBox.shrink();

    // 首页只露最近这几部，其余进「全部」列表页看。横排滑到第 11 张之后
    // 没人还记得自己在找哪一部，而列表页有分组、能按日期往回找。
    final preview = items.take(_previewCount).toList();
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final stripHeight = CompactWorkCard.heightFor(_cardWidth, textScale);

    return _Section(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(
            title: '最近浏览',
            trailing: TextButton(
              onPressed: () => context.push(RoutePaths.recentHistory),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text('全部', style: Theme.of(context).textTheme.labelMedium),
            ),
          ),
          SizedBox(
            height: stripHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: preview.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) =>
                  CompactWorkCard(work: preview[index].work, width: _cardWidth),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

/// 首页顶部「高分精选」大图卡。
///
/// 参考资讯类 / 番剧类客户端的 breaking banner：整行大图 + 底部渐变压暗 +
/// 标题与元信息。**只在手机端出现**——桌面首屏已经有侧栏和更宽的横排，
/// 再加一块大图会把首屏撑满。
///
/// 数据复用「高分作品」的前几条，不新开请求：首页是入口，不值得为一张
/// banner 多打一次接口。加载中给同高占位，避免数据到位后整页往下跳。
///
/// 手机端每 5 秒在「高分作品」里自动换一张（最多 5 张），右上角点状指示
/// 当前是第几张。定时器随页面销毁取消、切后台暂停——否则测试会报
/// pending timer，真机也会一直唤醒页面。
class _FeaturedHero extends ConsumerStatefulWidget {
  const _FeaturedHero();

  @override
  ConsumerState<_FeaturedHero> createState() => _FeaturedHeroState();
}

class _FeaturedHeroState extends ConsumerState<_FeaturedHero>
    with WidgetsBindingObserver {
  static const double _height = 200;

  /// 一次最多轮几张。10 张全轮一遍要近一分钟，用户看不到第一张之外的差别。
  static const int _maxSlides = 5;

  /// 轮换间隔。太短读不完标题，太长又像没在动。
  static const Duration _interval = Duration(seconds: 5);

  Timer? _timer;
  int _index = 0;

  /// 当前分支是否在前台可见。
  ///
  /// 切成 `StatefulShellRoute` 之后，非当前 tab 的页面**不会被销毁**，
  /// 只是被 `Offstage` + `TickerMode(enabled: false)` 藏起来。`Ticker`
  /// 会自动停，但 `Timer.periodic` 不会——不处理的话，人在资讯页时首页
  /// 仍在每 5 秒重建一次（看不见，但白耗电）。这里跟着 TickerMode 停表。
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startTimer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // `TickerMode.valuesOf` 建立了依赖：切 tab 时会回到这里。
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible == _visible) return;
    _visible = visible;
    if (visible) {
      _startTimer();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    // 必须取消：轮换是 Timer.periodic，留着会让测试报 pending timer，
    // 真机上也会一直唤醒页面。
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 后台停表：既省电，也避免回到前台时一次连跳好几张。
    if (state == AppLifecycleState.resumed) {
      _startTimer();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _startTimer() {
    _timer?.cancel();
    // 不可见就不排表：`didChangeAppLifecycleState(resumed)` 也会走到这里，
    // 回到前台时人在别的 tab，同样不该起表。
    if (!_visible) return;
    _timer = Timer.periodic(_interval, (_) => _advance());
  }

  void _advance() {
    if (!mounted || PlatformInfo.isDesktop) return;
    final items = ref.read(homeTopRatedProvider).value;
    if (items == null) return;
    final count = items.length < _maxSlides ? items.length : _maxSlides;
    if (count <= 1) return;
    setState(() => _index = (_index + 1) % count);
  }

  @override
  Widget build(BuildContext context) {
    if (PlatformInfo.isDesktop) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final topRated = ref.watch(homeTopRatedProvider);
    final radius = BorderRadius.circular(AppTheme.cardRadius);
    const padding = EdgeInsets.fromLTRB(
      AppLayout.pagePadding,
      4,
      AppLayout.pagePadding,
      4,
    );

    if (!topRated.hasValue) {
      return Padding(
        padding: padding,
        child: Container(
          height: _height,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: radius,
          ),
        ),
      );
    }

    final items = topRated.value ?? const <WorkSummary>[];
    if (items.isEmpty) return const SizedBox.shrink();

    // 刷新/数据变短时 _index 可能越界，取模即可；不额外 setState，避免 build 里改状态。
    final slides = items.length > _maxSlides
        ? items.sublist(0, _maxSlides)
        : items;
    final slideIndex = _index % slides.length;
    final work = slides[slideIndex];
    final rating = work.mainRating;
    final meta = [
      work.workType.label,
      if (work.releaseYear != null) '${work.releaseYear}',
      if (rating != null) '★ ${rating.value.toStringAsFixed(1)}',
    ].join(' · ');
    final firstChar = work.title.characters.isEmpty
        ? null
        : work.title.characters.first;

    return Padding(
      padding: padding,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: AppTheme.borderColor(context), width: 0.5),
          boxShadow: AppTheme.cardShadow,
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => context.push(RoutePaths.workDetail(work.workId)),
              child: SizedBox(
                height: _height,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 450),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      // 默认 layoutBuilder 只按子节点自身尺寸堆叠；这里的子节点是
                      // `StackFit.expand`，必须显式给 expand 约束，否则切换瞬间
                      // 会退回 0 尺寸、整块闪一下。
                      layoutBuilder: (currentChild, previousChildren) => Stack(
                        fit: StackFit.expand,
                        children: [...previousChildren, ?currentChild],
                      ),
                      child: KeyedSubtree(
                        key: ValueKey(work.workId),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            // 头图背景不贴来源角标：它会被压在标题/元信息上，
                            // 而且这张图的职责是氛围，不是「这条来自哪」。
                            CoverImage(
                              url: work.coverUrl,
                              width: double.infinity,
                              height: double.infinity,
                              radius: 0,
                              placeholderLabel: firstChar,
                              // 无封面时走深色渐变占位，而不是海报用的斜纹——
                              // 斜纹放大到 1000px 宽会变成一块喧宾夺主的条纹布。
                              placeholderStyle: CoverPlaceholderStyle.hero,
                            ),
                            // 底部压暗，保证白字在浅色封面上也能读。
                            const DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [Color(0x000B1620), Color(0xE60B1620)],
                                  stops: [0.35, 1],
                                ),
                              ),
                            ),
                            Positioned(
                              left: 16,
                              right: 16,
                              bottom: 14,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '高分精选',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: Colors.white.withValues(alpha: 0.75),
                                      letterSpacing: 1,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    work.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                      height: 1.25,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    meta,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: Colors.white.withValues(alpha: 0.85),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // 指示点放右上角：底部左侧是标题/元信息，放右边会被长标题压住。
                    if (slides.length > 1)
                      Positioned(
                        top: 12,
                        right: 12,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var i = 0; i < slides.length; i++)
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 250),
                                margin: const EdgeInsets.only(left: 4),
                                width: i == slideIndex ? 14 : 5,
                                height: 5,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(
                                    alpha: i == slideIndex ? 0.95 : 0.45,
                                  ),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
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

  static const double _gap = 10;

  static IconData _iconOf(WorkType type) => switch (type) {
    WorkType.anime => Icons.movie_outlined,
    WorkType.comic => Icons.auto_stories_outlined,
    WorkType.game => Icons.sports_esports_outlined,
    WorkType.novel => Icons.menu_book_outlined,
    WorkType.unknown => Icons.category_outlined,
  };

  /// 每种类型一个色相。分类入口是首页唯一「按类逛」的入口，四个都涂同一个
  /// 品牌蓝的话分不出来；这几个色都与品牌蓝相邻（靛/紫/粉/青），放在一起
  /// 不打架。图标与浅色底共用同一个色值，深浅主题都成立。
  static Color _colorOf(WorkType type) => switch (type) {
    WorkType.anime => const Color(0xFF4F6BFF),
    WorkType.comic => const Color(0xFFF2749B),
    WorkType.game => const Color(0xFF8B5CF6),
    WorkType.novel => const Color(0xFF12B3A6),
    WorkType.unknown => const Color(0xFF8A94A6),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 数量只是辅助信息：拿不到就只画标题，不占位、不显示 0。
    final counts = ref.watch(catalogCountsProvider).value;

    return _Section(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(title: '分类浏览'),
          LayoutBuilder(
            builder: (context, constraints) {
              // 手机两列、宽屏一行四个：四个胶囊式小按钮在手机上一眼找不到，
              // 版面上也压不住首屏。
              final columns = constraints.maxWidth >= 560 ? 4 : 2;
              final tileWidth =
                  (constraints.maxWidth - _gap * (columns - 1)) / columns;
              return Wrap(
                spacing: _gap,
                runSpacing: _gap,
                children: [
                  for (final type in WorkType.selectable)
                    SizedBox(
                      width: tileWidth,
                      child: _TypeTile(
                        key: ValueKey('home-type-${type.value}'),
                        type: type,
                        icon: _iconOf(type),
                        color: _colorOf(type),
                        count: counts?.countOf(type),
                        onTap: () {
                          ref
                              .read(contentsFilterProvider.notifier)
                              .showType(type);
                          context.go(RoutePaths.contents);
                        },
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

/// 分类磁贴：彩色图标块 + 类型名 + 数量。
class _TypeTile extends StatelessWidget {
  const _TypeTile({
    super.key,
    required this.type,
    required this.icon,
    required this.color,
    required this.count,
    required this.onTap,
  });

  final WorkType type;
  final IconData icon;
  final Color color;
  final int? count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: AppTheme.cardColor(context),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppLayout.cardRadius),
        side: BorderSide(color: AppTheme.borderColor(context), width: 0.5),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, size: 24, color: color),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      type.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (count != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        '${formatCompactCount(count!)} 部',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 数量压缩：198100 → 19.8 万。分类磁贴一行只有 ~120px，五位数字放不下。
String formatCompactCount(int value) {
  if (value < 10000) return '$value';
  final wan = value / 10000;
  return '${wan.toStringAsFixed(wan >= 100 ? 0 : 1)} 万';
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
            emptyIcon: Icons.event_busy_outlined,
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
        // 与作品卡 / 资讯卡同一套容器：白底 + 0.5 描边 + 卡圆角 + 极轻阴影。
        color: AppTheme.cardColor(context),
        elevation: 1,
        shadowColor: const Color(0x2E143652),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.cardRadius),
          side: BorderSide(color: AppTheme.borderColor(context), width: 0.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.cardRadius),
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
            emptyIcon: Icons.auto_awesome_outlined,
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
            emptyIcon: Icons.newspaper_outlined,
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
