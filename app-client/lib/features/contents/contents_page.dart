import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../../core/router/route_paths.dart';
import '../../core/platform_info.dart';
import '../../core/theme/app_layout.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/work_sort.dart';
import '../../data/models/work_type.dart';
import '../../shared/widgets/account_menu.dart';
import '../../shared/widgets/desktop_nav_shell.dart';
import '../../shared/widgets/desktop_shortcuts.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/error_state.dart';
import '../../shared/widgets/offline_notice.dart';
import '../../shared/widgets/skeleton_list.dart';
import 'catalog_counts.dart';
import 'contents_controller.dart';
import 'work_card.dart';
import 'work_list_tile.dart';

/// 列表的呈现方式。
///
/// 站点给了三种（卡片 / 网格 / 列表），这里只有两种：「卡片」视图的核心是
/// 两行摘要 + 排名角标，而列表接口不返回 `summary`、契约里也没有 rank 字段，
/// 做出来会和网格视图长得一模一样，不如不做。
enum CatalogView { grid, list }

class CatalogViewController extends Notifier<CatalogView> {
  @override
  CatalogView build() => CatalogView.grid;

  void select(CatalogView view) {
    if (state == view) return;
    state = view;
  }
}

/// 会话内记住偏好即可：项目里还没有通用的本地偏好存储，
/// 为了一个视图开关单独引一个插件不值当。
final catalogViewProvider =
    NotifierProvider<CatalogViewController, CatalogView>(
      CatalogViewController.new,
    );

/// 作品列表：搜索 + 类型筛选 + 无限滚动分页 + 网格/列表切换。
///
/// 状态矩阵（验收时逐条对）：
/// - 首屏加载 → 骨架屏（与当前视图同构，切换视图不会跳一下）
/// - 无数据 / 搜索无结果 → 空状态
/// - 首屏失败 → 错误状态 + 重试
/// - 加载下一页失败 → 底部重试条，**不清空已有数据**
class ContentsPage extends ConsumerStatefulWidget {
  const ContentsPage({super.key});

  @override
  ConsumerState<ContentsPage> createState() => _ContentsPageState();
}

class _ContentsPageState extends ConsumerState<ContentsPage> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  Timer? _debounce;

  /// 换筛选条件后要把列表拉回顶部：`ScrollController` 默认会恢复上一份数据的
  /// 偏移，从长列表（10000 条）切到短列表时会停在中间，看起来像"跳页"。
  /// 数据是异步换的，所以先打标记，等新列表挂上去后再跳。
  bool _pendingScrollReset = false;

  void _requestScrollReset() {
    if (_scrollController.hasClients && _scrollController.offset == 0) return;
    _pendingScrollReset = true;
    _flushScrollReset();
  }

  void _flushScrollReset() {
    if (!_pendingScrollReset) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 还在骨架屏阶段，没有可跳的位置；等下一次 build 再接。
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(0);
      _pendingScrollReset = false;
    });
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    // 从详情返回时，搜索框要保留已经生效的关键词。
    _searchController.text = ref.read(contentsFilterProvider).query;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.maxScrollExtent - position.pixels < 320) {
      ref.read(contentsControllerProvider.notifier).loadMore();
    }
  }

  void _handleQueryChanged(String value) {
    // 输入时不要每个字符都打一次接口，300ms 后再查。
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      ref.read(contentsFilterProvider.notifier).search(value);
    });
  }

  /// 物理键盘回车 / 触摸键盘的「搜索」键：不等 300ms 防抖，立刻查。
  ///
  /// 桌面端用户敲完标题会顺手回车（§6「搜索」一行要求 Enter 提交），
  /// 让他再干等 300ms 没有意义。
  void _submitSearch(String value) {
    _debounce?.cancel();
    ref.read(contentsFilterProvider.notifier).search(value);
  }

  void _clearQuery() {
    _debounce?.cancel();
    _searchController.clear();
    ref.read(contentsFilterProvider.notifier).search('');
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(contentsFilterProvider);
    final contents = ref.watch(contentsControllerProvider);
    final view = ref.watch(catalogViewProvider);
    final counts = ref.watch(catalogCountsProvider).value;

    ref.listen<ContentsFilter>(contentsFilterProvider, (previous, next) {
      if (previous == null || previous == next) return;
      _requestScrollReset();
    });
    // 两种视图的行高完全不同，沿用旧偏移会落到毫无关系的位置。
    ref.listen<CatalogView>(catalogViewProvider, (previous, next) {
      if (previous == null || previous == next) return;
      _requestScrollReset();
    });

    // "共 N 部"只认当前条件的数据，切换条件时的旧值不能拿来显示。
    final data = contents.value;
    final liveTotal = data != null && data.filter == filter ? data.total : null;
    // 离线提示同理：换条件时 Riverpod 会把上一组数据留在 AsyncValue 里，
    // 那份数据不属于当前条件，拿它的「来自缓存」状态说事是错的。
    final cacheNotice = data != null && data.filter == filter && data.fromCache
        ? data
        : null;

    return DesktopNavShell(
      child: DesktopShortcuts(
        onRefresh: () =>
            ref.read(contentsControllerProvider.notifier).refresh(),
        child: Scaffold(
          appBar: AppBar(
            title: const Text('作品库'),
            actions: [
              // 桌面端没有下拉手势，刷新得有个按钮（§6「刷新」一行）。
              // 手机端保持只有下拉刷新：多一个按钮只是挤占 AppBar。
              if (PlatformInfo.isDesktop)
                IconButton(
                  tooltip: '刷新（Ctrl+R）',
                  onPressed: () =>
                      ref.read(contentsControllerProvider.notifier).refresh(),
                  icon: const Icon(Icons.refresh_rounded),
                ),
              IconButton(
                tooltip: '我的收藏',
                onPressed: () => context.push(RoutePaths.collections),
                icon: const Icon(Icons.bookmark_border_rounded),
              ),
              // 排序放在 AppBar 而不是筛选栏：筛选栏已经塞了类型 chips 和
              // 视图切换，再放一个控件会在手机上把 chips 挤到只剩一两个。
              _SortMenu(
                current: filter.sort,
                onChanged: (sort) => ref
                    .read(contentsFilterProvider.notifier)
                    .selectSort(sort),
              ),
              // 账号入口放在这里而不是收藏页：登录是全局动作，用户不该为了
              // 登录先进「我的收藏」再点右上角。三态（检查中/未登录/已登录）
              // 由组件自己处理，本页不关心。
              const AccountMenuButton(),
              const SizedBox(width: 8),
            ],
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppLayout.listMaxWidth,
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppLayout.pagePadding,
                      4,
                      AppLayout.pagePadding,
                      0,
                    ),
                    child: TextField(
                      controller: _searchController,
                      onChanged: _handleQueryChanged,
                      onSubmitted: _submitSearch,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: '搜索作品标题',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: filter.query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: '清除',
                                icon: const Icon(Icons.close),
                                onPressed: _clearQuery,
                              ),
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  _FilterRow(
                    selected: filter.type,
                    counts: counts,
                    total: liveTotal,
                    view: view,
                    onSelected: (type) => ref
                        .read(contentsFilterProvider.notifier)
                        .selectType(type),
                    onViewChanged: (next) =>
                        ref.read(catalogViewProvider.notifier).select(next),
                  ),
                  // 离线提示。放在筛选栏下面、列表上面：用户先看到内容，
                  // 紧接着看到「这是缓存」的说明，而不是被一条横幅挡在内容之外。
                  if (cacheNotice != null)
                    OfflineNotice(
                      cachedAt: cacheNotice.cachedAt,
                      onRetry: () =>
                          ref.read(contentsControllerProvider.notifier).refresh(),
                    ),
                  Expanded(child: _buildBody(filter, contents, view)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    ContentsFilter filter,
    AsyncValue<ContentsData> contents,
    CatalogView view,
  ) {
    final data = contents.value;
    // 换条件后 Riverpod 会把上一组数据保留在 AsyncLoading/AsyncError 里，
    // 那份数据不属于当前条件，不能当结果展示。
    final isStale = data != null && data.filter != filter;

    if (contents.isLoading && (data == null || isStale)) {
      return view == CatalogView.list
          ? const SkeletonList()
          : const SkeletonGrid();
    }

    if (contents.hasError) {
      final error = ApiException.fromAny(contents.error);
      if (data == null || isStale) {
        return ErrorState(
          error: error,
          onRetry: () => ref.invalidate(contentsControllerProvider),
        );
      }
      // 同一条件刷新失败：已有内容继续展示，但必须把失败明说出来，
      // 否则用户会以为看到的就是最新数据（契约 7：不能静默失败）。
      return Column(
        children: [
          _RefreshErrorBar(
            error: error,
            onRetry: () => ref.invalidate(contentsControllerProvider),
          ),
          Expanded(child: _buildList(data, view)),
        ],
      );
    }

    final resolved = contents.requireValue;
    if (resolved.items.isEmpty) return _buildEmpty(filter);
    return _buildList(resolved, view);
  }

  Widget _buildEmpty(ContentsFilter filter) {
    final searching = filter.query.isNotEmpty;
    final hasType = filter.type != null;

    return RefreshIndicator(
      onRefresh: () => ref.read(contentsControllerProvider.notifier).refresh(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 72),
          EmptyState(
            icon: searching
                ? Icons.search_off_rounded
                : Icons.movie_filter_outlined,
            title: searching ? '没有匹配的作品' : '这里还没有作品',
            message: searching
                ? '换个更短的关键词试试，搜索只匹配标题，不支持拼音与别名'
                : (hasType ? '这个分类下暂时没有内容，换个分类看看' : '等同步任务跑完就有了'),
          ),
        ],
      ),
    );
  }

  Widget _buildList(ContentsData data, CatalogView view) {
    _flushScrollReset();
    return RefreshIndicator(
      onRefresh: () => ref.read(contentsControllerProvider.notifier).refresh(),
      child: view == CatalogView.list ? _buildRows(data) : _buildGrid(data),
    );
  }

  Widget _buildGrid(ContentsData data) {
    // 海报网格：列数按可用宽度算，卡片高度写死，保证长短标题不会让行高参差。
    return LayoutBuilder(
      builder: (context, constraints) {
        final usable = constraints.maxWidth - AppLayout.pagePadding * 2;
        final metrics = AppLayout.gridMetrics(usable);
        // 正文高度跟着系统字体缩放（与收藏页网格同一套做法）：大字体下固定
        // 高度会撑爆卡片，真机 font_scale 2.0 实测底部溢出 20px。
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final extent =
            metrics.cardWidth / AppLayout.posterAspect +
            AppLayout.cardBodyHeight * textScale;

        return CustomScrollView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                AppLayout.pagePadding,
                8,
                AppLayout.pagePadding,
                0,
              ),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: metrics.columns,
                  mainAxisExtent: extent,
                  crossAxisSpacing: AppLayout.gridGap,
                  mainAxisSpacing: AppLayout.gridGap,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => WorkCard(work: data.items[index]),
                  childCount: data.items.length,
                ),
              ),
            ),
            _buildFooterSliver(data),
          ],
        );
      },
    );
  }

  Widget _buildRows(ContentsData data) {
    return CustomScrollView(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppLayout.pagePadding,
            8,
            AppLayout.pagePadding,
            0,
          ),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => Padding(
                padding: const EdgeInsets.only(bottom: AppLayout.gridGap),
                child: WorkListTile(work: data.items[index]),
              ),
              childCount: data.items.length,
            ),
          ),
        ),
        _buildFooterSliver(data),
      ],
    );
  }

  Widget _buildFooterSliver(ContentsData data) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppLayout.pagePadding,
          12,
          AppLayout.pagePadding,
          24,
        ),
        child: _buildFooter(data),
      ),
    );
  }

  Widget _buildFooter(ContentsData data) {
    if (data.isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    final error = data.loadMoreError;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                error.userMessage,
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            TextButton(
              onPressed: () =>
                  ref.read(contentsControllerProvider.notifier).loadMore(),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    // 只有确实翻过页才提示到底，单页列表不需要这句话。
    if (!data.hasMore && data.items.length >= AppConfig.pageSize) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text(
            '已经到底了',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return const SizedBox(height: 8);
  }
}

/// 排序菜单。契约只认 `id` / `rating` / `year` 三种取值，非法值服务端返回 400，
/// 所以这里不给自由输入，只能三选一，当前项打勾。
///
/// 改排序要重新请求第一页（服务端手里才有全量数据，本地重排只排得动已加载的
/// 那一页），这一点由 [ContentsFilter.sort] 变化触发 controller 重跑来实现。
class _SortMenu extends StatelessWidget {
  const _SortMenu({required this.current, required this.onChanged});

  final WorkSort current;
  final ValueChanged<WorkSort> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<WorkSort>(
      tooltip: '排序（当前：${current.label}）',
      icon: const Icon(Icons.sort_rounded),
      initialValue: current,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final sort in WorkSort.values)
          CheckedPopupMenuItem<WorkSort>(
            value: sort,
            checked: sort == current,
            child: Text(sort.label),
          ),
      ],
    );
  }
}

/// 筛选栏：类型胶囊（带作品数）+ 结果数 + 视图切换。
///
/// 数量来自 [catalogCountsProvider]，对应站点 `.type-tab-count`；
/// 拿不到就只显示文字，不占位、不显示 0。
class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.selected,
    required this.counts,
    required this.total,
    required this.view,
    required this.onSelected,
    required this.onViewChanged,
  });

  final WorkType? selected;
  final CatalogCounts? counts;
  final int? total;
  final CatalogView view;
  final ValueChanged<WorkType?> onSelected;
  final ValueChanged<CatalogView> onViewChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 窄屏优先保住胶囊和视图开关，结果数最先让位。
          final showTotal = total != null && constraints.maxWidth >= 560;
          return Row(
            children: [
              Expanded(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(
                    left: AppLayout.pagePadding,
                    right: 8,
                  ),
                  children: [
                    _chip(context, label: '全部', type: null),
                    for (final type in WorkType.selectable)
                      _chip(context, label: type.label, type: type),
                  ],
                ),
              ),
              if (showTotal)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Text(
                    '共 $total 部',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(right: AppLayout.pagePadding),
                child: _ViewSwitch(value: view, onChanged: onViewChanged),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _chip(
    BuildContext context, {
    required String label,
    required WorkType? type,
  }) {
    final isSelected = selected == type;
    final count = counts?.countOf(type);

    return Padding(
      padding: const EdgeInsets.only(right: 8, top: 8, bottom: 8),
      child: ChoiceChip(
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label),
            if (count != null) ...[
              const SizedBox(width: 6),
              Text(
                '$count',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  // 数量是次要信息，但不能淡到看不清——之前用 outlineVariant
                  // 在浅蓝底上几乎看不见。
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
        selected: isSelected,
        onSelected: (_) => onSelected(type),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

/// 视图切换。做成站点 `.view-switch` 那种双段胶囊，比两个独立图标按钮更明确。
class _ViewSwitch extends StatelessWidget {
  const _ViewSwitch({required this.value, required this.onChanged});

  final CatalogView value;
  final ValueChanged<CatalogView> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderColor(context)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _segment(
            context,
            icon: Icons.grid_view_rounded,
            tooltip: '网格视图',
            target: CatalogView.grid,
          ),
          _segment(
            context,
            icon: Icons.view_list_rounded,
            tooltip: '列表视图',
            target: CatalogView.list,
          ),
        ],
      ),
    );
  }

  Widget _segment(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    required CatalogView target,
  }) {
    final theme = Theme.of(context);
    final isSelected = value == target;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => onChanged(target),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 34,
          height: 28,
          decoration: BoxDecoration(
            color: isSelected
                ? AppTheme.cardColor(context)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            boxShadow: isSelected
                ? const [
                    BoxShadow(
                      color: Color(0x1A143652),
                      blurRadius: 3,
                      offset: Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: Icon(
            icon,
            size: 18,
            color: isSelected
                ? theme.colorScheme.onSurface
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 刷新失败提示条：保留已有内容，但把失败和重试入口摆在列表上方。
class _RefreshErrorBar extends StatelessWidget {
  const _RefreshErrorBar({required this.error, required this.onRetry});

  final ApiException error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppLayout.pagePadding,
        8,
        AppLayout.pagePadding,
        0,
      ),
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.wifi_off_rounded,
            size: 18,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error.userMessage,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
