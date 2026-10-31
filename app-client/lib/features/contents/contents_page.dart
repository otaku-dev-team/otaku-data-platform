import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../../core/router/route_paths.dart';
import '../../core/platform_info.dart';
import '../../core/theme/app_layout.dart';
import '../../shared/widgets/cover_prefetch.dart';
import '../settings/display_settings.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/tag_vocabulary.dart';
import '../../data/models/work_sort.dart';
import '../../data/models/work_type.dart';
import '../../shared/widgets/account_menu.dart';
import '../../shared/widgets/desktop_nav_shell.dart';
import '../../shared/widgets/mobile_nav_bar.dart';
import '../../shared/widgets/desktop_shortcuts.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/error_state.dart';
import '../../shared/widgets/offline_notice.dart';
import '../../shared/widgets/skeleton_list.dart';
import 'catalog_counts.dart';
import 'contents_controller.dart';
import 'tag_picker.dart';
import 'tag_vocabulary_provider.dart';
import 'search_history_controller.dart';
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
  final FocusNode _searchFocus = FocusNode();
  Timer? _debounce;

  /// 搜索框是否聚焦。历史 chips 只在聚焦且输入框为空时出现——
  /// 平时挂在筛选栏上方会白占一行高度，用户没在搜索时那是没用的信息。
  bool _searchFocused = false;

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
    _searchFocus.addListener(_handleSearchFocus);
    // 从详情返回时，搜索框要保留已经生效的关键词。
    _searchController.text = ref.read(contentsFilterProvider).query;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchFocus.removeListener(_handleSearchFocus);
    _searchFocus.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleSearchFocus() {
    if (!mounted) return;
    if (_searchFocused == _searchFocus.hasFocus) return;
    setState(() => _searchFocused = _searchFocus.hasFocus);
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
  ///
  /// **只有这里和点历史 chip 会写历史**：边打字边搜的那条防抖链路不写，
  /// 否则一次输入会在历史里留下「进」「进击」「进击的」三行（见
  /// `SearchHistoryController` 的注释）。
  void _submitSearch(String value) {
    _debounce?.cancel();
    ref.read(searchHistoryProvider.notifier).record(value);
    ref.read(contentsFilterProvider.notifier).search(value);
  }

  /// 点一条历史 chip：填回输入框并立刻搜。
  ///
  /// 走 [_submitSearch] 的同一套动作，但不经过输入框的 `onChanged`——
  /// 程序化改 `text` 不会触发它，所以这里要手动填一次再把光标放到末尾。
  void _applyHistory(String query) {
    _debounce?.cancel();
    _searchController.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
    ref.read(searchHistoryProvider.notifier).record(query);
    ref.read(contentsFilterProvider.notifier).search(query);
    // 收键盘：用户已经选完了，键盘继续占着半屏只会挡住结果。
    _searchFocus.unfocus();
  }

  void _clearQuery() {
    _debounce?.cancel();
    _searchController.clear();
    ref.read(contentsFilterProvider.notifier).search('');
  }

  /// 点「热门标签」：按标签筛选，不是把词填进搜索框。
  ///
  /// `q` 只匹配标题（实测「科幻」当搜索词 7 条、当标签筛 2579 条），
  /// 填进输入框只会让用户以为搜索坏了。
  void _applySuggestedTag(String tag) {
    _debounce?.cancel();
    _searchController.clear();
    ref.read(contentsFilterProvider.notifier).search('');
    ref.read(contentsFilterProvider.notifier).toggleTag(tag);
    // 收键盘：用户已经选完了，键盘继续占着半屏只会挡住结果。
    _searchFocus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(contentsFilterProvider);
    final contents = ref.watch(contentsControllerProvider);
    final view = ref.watch(catalogViewProvider);
    final counts = ref.watch(catalogCountsProvider).value;
    final searchHistory = ref.watch(searchHistoryProvider);
    // 聚焦 + 输入框为空 → 展开「前置面板」（历史 + 热门标签）。
    // 输入框里已经有词时不显示：那一栏会变成「建议 vs 当前查询」两个焦点，
    // 用户还得先分辨哪个才是自己在搜的。
    final searchIdle = _searchFocused && filter.query.trim().isEmpty;
    // 只在面板展开时才取热门标签：这一页不聚焦时不该为一个提示多打一次请求。
    final hotTags = searchIdle
        ? ref.watch(hotTagSuggestionsProvider).value ?? const <TagCount>[]
        : const <TagCount>[];
    final showSearchSuggestions =
        searchIdle && (searchHistory.isNotEmpty || hotTags.isNotEmpty);

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

    // 按评分排序时，无评分条目由服务端沉到末尾（rating_value DESC）。
    // 这个顺序必须解释一句：否则末尾那一片「没有徽标」的卡片会被读成
    // 加载失败，而不是「这些作品本来就没分」（W1.5 D2）。
    final ratingSort = filter.sort == WorkSort.rating;
    final showMissingRating = ratingSort;
    final showRatingNotice =
        ratingSort &&
        liveTotal != null &&
        data!.items.any((item) => item.mainRating == null);

    return DesktopNavShell(
      child: DesktopShortcuts(
        onRefresh: () =>
            ref.read(contentsControllerProvider.notifier).refresh(),
        // 桌面端按 `/` 直接聚焦搜索框：这一页最常用的动作不该要求用户先去点一下。
        onSearch: _searchFocus.requestFocus,
        // 搜索框有焦点时 Esc 先「退出输入」；否则会把整个作品库页弹掉——
        // 用户想关掉输入法/光标，结果整页没了。
        onEscape: () {
          if (!_searchFocus.hasFocus) return false;
          _searchFocus.unfocus();
          return true;
        },
        child: Scaffold(
          bottomNavigationBar: MobileNavBar.forScaffold(context),
          appBar: AppBar(
            title: const Text('作品库'),
            actions: [
              // 手机端这三个入口底栏已经有了（资讯 / 收藏 / 新番），
              // AppBar 再放一份不只是重复：真机 1080×2400 实测，
              // 标题「作品库」被挤成「作...」。桌面没有底栏，保留这三个入口。
              if (PlatformInfo.isDesktop) ...[
                // 桌面端没有下拉手势，刷新得有个按钮（§6「刷新」一行）。
                // 手机端保持只有下拉刷新：多一个按钮只是挤占 AppBar。
                IconButton(
                  tooltip: '刷新（Ctrl+R）',
                  onPressed: () =>
                      ref.read(contentsControllerProvider.notifier).refresh(),
                  icon: const Icon(Icons.refresh_rounded),
                ),
                IconButton(
                  tooltip: '最新资讯',
                  onPressed: () => context.push(RoutePaths.articles),
                  icon: const Icon(Icons.newspaper_outlined),
                ),
                IconButton(
                  tooltip: '我的收藏',
                  onPressed: () => context.push(RoutePaths.collections),
                  icon: const Icon(Icons.bookmark_border_rounded),
                ),
                // 每日新番入口。与收藏并列而不是塞进筛选栏：筛选栏已经
                // 被类型 chips 和排序占满，再放一个入口会把 chips 挤没。
                IconButton(
                  tooltip: '每日新番',
                  onPressed: () => context.push(RoutePaths.schedule),
                  icon: const Icon(Icons.calendar_today_outlined),
                ),
              ],
              // 年份筛选。与排序并列：两个都是「对整个结果集生效」的条件，
              // 塞进类型 chips 那条横向列表会被挤到看不见。
              _YearMenu(
                current: filter.year,
                onChanged: (year) => ref
                    .read(contentsFilterProvider.notifier)
                    .selectYear(year),
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
                      focusNode: _searchFocus,
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
                  if (showSearchSuggestions)
                    _SearchSuggestions(
                      queries: searchHistory,
                      hotTags: hotTags,
                      onSelectHistory: _applyHistory,
                      onSelectTag: _applySuggestedTag,
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
                    tags: filter.tags,
                    onTagsPressed: () => _openTagPicker(filter),
                  ),
                  // 当前筛选状态 + 逐项清除入口。
                  //
                  // 筛选条件**必须显式可见**：卡片上的标签被标了色，但
                  // 一屏 50 张卡里只看一张时，用户很容易不知道自己筛过标签，
                  // 也不知道为什么结果变少了。空结果时尤其重要——
                  // 「按『科幻』筛出 0 部」和「库里没有科幻」是两回事。
                  if (filter.tags.isNotEmpty || filter.year != null)
                    _ActiveFiltersBar(
                      filter: filter,
                      // `tag` 与 `q` 同用约 720ms（后端实测：LIKE '%kw%' 与
                      // 标签求交集，两边都定位不了索引）。这不是客户端能绕过的，
                      // 所以先选标签时把搜索框禁用并说明原因，
                      // 而不是让用户组合出一个 0.7 秒的查询还不知情。
                      searchBlocked: filter.query.isNotEmpty,
                    ),
                  // 离线提示。放在筛选栏下面、列表上面：用户先看到内容，
                  // 紧接着看到「这是缓存」的说明，而不是被一条横幅挡在内容之外。
                  if (cacheNotice != null)
                    OfflineNotice(
                      cachedAt: cacheNotice.cachedAt,
                      onRetry: () =>
                          ref.read(contentsControllerProvider.notifier).refresh(),
                    ),
                  
                  if (showRatingNotice) const _RatingSortNotice(),
                  Expanded(
                    child: _buildBody(filter, contents, view, showMissingRating),
                  ),
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
    bool showMissingRating,
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
          Expanded(child: _buildList(data, view, showMissingRating)),
        ],
      );
    }

    final resolved = contents.requireValue;
    if (resolved.items.isEmpty) return _buildEmpty(filter);
    return _buildList(resolved, view, showMissingRating);
  }

  Widget _buildEmpty(ContentsFilter filter) {
    final searching = filter.query.isNotEmpty;
    final hasType = filter.type != null;
    final tags = filter.tags;
    final year = filter.year;

    // 按标签筛出 0 条与「库里没有东西」是两回事，文案必须分开：
    // 契约里未知标签返 `200 + 空数组`（不是 404），所以这一屏是**筛太窄**，
    // 不是**没数据**。说成「这里还没有作品」会让用户以为同步没跑完。
    final filtering =
        searching || hasType || tags.isNotEmpty || year != null;
    final (title, message) = switch (null) {
      // 多标签是 AND：选的越多越窄，空结果时最该解释的就是这层关系，
      // 否则用户会以为是「标签库里没数据」。
      _ when tags.length > 1 => (
        '这几个标签没有同时命中的作品',
        '标签之间是「并且」关系——「${tags.join('」「')}」得同时命中。'
            '去掉一个标签再看看',
      ),
      _ when tags.length == 1 && searching => (
        '这个标签下没有匹配的作品',
        '「${tags.first}」与关键词「${filter.query}」同时筛选超出了当前检索能力，'
            '去掉一个条件试试',
      ),
      _ when tags.length == 1 => (
        '没有这个标签的作品',
        '「${tags.first}」是精确匹配——「科幻」不会包含「科幻机甲」。'
            '换个标签或清除筛选看看',
      ),
      _ when year != null => (
        '$year 年没有作品',
        '年份是精确匹配；换一年，或清除筛选看看全部内容',
      ),
      _ when searching => (
        '没有匹配的作品',
        '换个更短的关键词试试，搜索只匹配标题，不支持拼音与别名',
      ),
      _ when hasType => ('这个分类下暂时没有内容', '换个分类看看'),
      _ => ('这里还没有作品', '等同步任务跑完就有了'),
    };

    return RefreshIndicator(
      color: AppTheme.brandStrong,
      onRefresh: () => ref.read(contentsControllerProvider.notifier).refresh(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 72),
          EmptyState(
            icon: filtering
                ? Icons.search_off_rounded
                : Icons.movie_filter_outlined,
            title: title,
            message: message,
            // 筛太窄时给一个出口：现在「标签」有自己的清除按钮，但类型和
            // 关键词只能靠用户自己想起来去改——空结果这一屏是最该有出口的地方。
            // 完全没数据时不给按钮：那不是一个能靠点击解决的问题。
            action: filtering
                ? FilledButton.tonal(
                    onPressed: _clearFilters,
                    child: const Text('清除筛选'),
                  )
                : null,
          ),
        ],
      ),
    );
  }

  /// 打开标签面板；用户点了「应用」才替换条件（取消不动）。
  Future<void> _openTagPicker(ContentsFilter filter) async {
    final picked = await showTagPicker(
      context,
      selected: filter.tags,
      type: filter.type,
    );
    if (picked == null || !mounted) return;
    ref.read(contentsFilterProvider.notifier).selectTags(picked);
  }

  /// 清空筛选条件，并把搜索框的可见文本一起清掉。
  ///
  /// 只清 provider 不清输入框的话，用户会看到空列表配着一个还写着关键词的
  /// 输入框——他会以为按钮没生效。
  void _clearFilters() {
    _debounce?.cancel();
    _searchController.clear();
    ref.read(contentsFilterProvider.notifier).clearFilters();
  }

  Widget _buildList(
    ContentsData data,
    CatalogView view,
    bool showMissingRating,
  ) {
    _flushScrollReset();
    return RefreshIndicator(
      color: AppTheme.brandStrong,
      onRefresh: () => ref.read(contentsControllerProvider.notifier).refresh(),
      child: view == CatalogView.list
          ? _buildRows(data, showMissingRating)
          : _buildGrid(data, showMissingRating),
    );
  }

  Widget _buildGrid(ContentsData data, bool showMissingRating) {
    // 海报网格：列数按可用宽度算，卡片高度写死，保证长短标题不会让行高参差。
    return LayoutBuilder(
      builder: (context, constraints) {
        // 在 builder 里 watch：切密度只重建网格，不重建整页（搜索框、筛选栏
        // 都不该跟着重来一遍）。
        final display = ref.watch(libraryDisplayProvider);
        final usable = constraints.maxWidth - AppLayout.pagePadding * 2;
        final metrics = AppLayout.gridMetrics(
          usable,
          density: display.density,
          overrideColumns: display.columns,
        );
        // 正文高度跟着系统字体缩放（与收藏页网格同一套做法）：大字体下固定
        // 高度会撑爆卡片，真机 font_scale 2.0 实测底部溢出 20px。
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final extent = AppLayout.gridCellExtent(
          cardWidth: metrics.cardWidth,
          density: display.density,
          textScale: textScale,
        );

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
                  (context, index) => WorkCard(
                    work: data.items[index],
                    showMissingRating: showMissingRating,
                    density: display.density,
                  ),
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

  Widget _buildRows(ContentsData data, bool showMissingRating) {
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
              (context, index) {
                // 建到某一项时顺手把后面几张的封面预取进缓存：滚过去的时候
                // 文件已经在磁盘里，不用从占位灰等起。重复调用会被 ImageCache 去重。
                prefetchCovers(context, data.items.skip(index + 1));
                return Padding(
                  padding: const EdgeInsets.only(bottom: AppLayout.gridGap),
                  child: WorkListTile(
                    work: data.items[index],
                    showMissingRating: showMissingRating,
                  ),
                );
              },
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

/// 当前标签筛选条：说清「正在按哪个标签筛」并给一个清除出口。
///
/// 单独一条而不是把提示混进空结果页：筛出 0 条时列表会显示空状态，
/// 那时用户最容易困惑「是我筛错了，还是库里真没有」——这一条正好回答它。
class _ActiveFiltersBar extends ConsumerWidget {
  const _ActiveFiltersBar({required this.filter, required this.searchBlocked});

  final ContentsFilter filter;

  /// 搜索框里已经有词了。`tag` + `q` 同用是一次约 720ms 的查询
  /// （后端实测），所以这个组合要明确提示，而不是让它悄悄变慢。
  final bool searchBlocked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(contentsFilterProvider.notifier);

    return Padding(
      padding: const EdgeInsets.only(
        left: AppLayout.pagePadding,
        right: AppLayout.pagePadding,
        top: 2,
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final tag in filter.tags)
            InputChip(
              avatar: const Icon(Icons.sell_outlined, size: 14),
              label: Text('标签：$tag'),
              visualDensity: VisualDensity.compact,
              deleteButtonTooltipMessage: '取消「$tag」',
              onDeleted: () => controller.toggleTag(tag),
            ),
          if (filter.year != null)
            InputChip(
              avatar: const Icon(Icons.date_range_rounded, size: 14),
              label: Text('年份：${filter.year} 年'),
              visualDensity: VisualDensity.compact,
              deleteButtonTooltipMessage: '取消年份筛选',
              onDeleted: () => controller.selectYear(null),
            ),
          if (filter.tags.isNotEmpty && searchBlocked)
            Text(
              '标签与关键词同时筛选较慢',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

/// 年份筛选菜单。
///
/// 为什么用菜单而不是下拉框：候选是 1950–今年，下拉会拖成很长一条；
/// PopupMenu 自带滚动与勾选态，而且和旁边的排序菜单是同一个交互。
///
/// 菜单项的 value 用 `0` 表示「全部年份」——`PopupMenuButton` 把 `null`
/// 当作「点了外面关掉」，用 null 当选项值会让「取消筛选」永远点不动。
class _YearMenu extends StatelessWidget {
  const _YearMenu({required this.current, required this.onChanged});

  final int? current;
  final ValueChanged<int?> onChanged;

  static const int _allValue = 0;

  @override
  Widget build(BuildContext context) {
    final thisYear = DateTime.now().year;

    return PopupMenuButton<int>(
      tooltip: '年份筛选（当前：${current == null ? '全部' : '$current 年'}）',
      icon: Icon(
        Icons.date_range_rounded,
        // 有条件生效时给个颜色提示：筛选栏里的 chip 在手机上可能要滚出视野，
        // 图标是唯一一直可见的状态位。
        color: current == null ? null : AppTheme.brandInk(context),
      ),
      initialValue: current ?? _allValue,
      constraints: const BoxConstraints(maxHeight: 420),
      onSelected: (value) => onChanged(value == _allValue ? null : value),
      itemBuilder: (context) => [
        CheckedPopupMenuItem<int>(
          value: _allValue,
          checked: current == null,
          child: const Text('全部年份'),
        ),
        for (var year = thisYear; year >= 1950; year--)
          CheckedPopupMenuItem<int>(
            value: year,
            checked: current == year,
            child: Text('$year 年'),
          ),
      ],
    );
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
    required this.tags,
    required this.onTagsPressed,
  });

  final WorkType? selected;
  final CatalogCounts? counts;
  final int? total;
  final CatalogView view;
  final ValueChanged<WorkType?> onSelected;
  final ValueChanged<CatalogView> onViewChanged;

  /// 当前选中的标签（决定入口上的计数与高亮）。
  final List<String> tags;
  final VoidCallback onTagsPressed;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 窄屏上胶囊只留文字：每个都带 5 位数会占满一行，剩下的类型
        // 全靠横滑找。数量单独一行显示总数，宽屏再恢复站点那种
        // 「类型 + 数量」的胶囊。
        final narrow = constraints.maxWidth < 560;
        final showChipCounts = !narrow;
        final scheme = Theme.of(context).colorScheme;

        // **换行而不是横滑**。
        //
        // 以前是「52px 固定高度 + 横向 ListView」：右侧还要挤总数与视图切换，
        // 结果一屏只放得下三枚，剩下的类型（以及标签入口）必须横滑才找得到，
        // 最右那枚还会被切掉半个——用户会直接认定「布局挡到了」。
        //
        // 现在这块不再限高（外层是 Column），换成 Wrap：六枚在两行内排完，
        // 一眼看到全部筛选维度，没有隐藏项，也没有横滑手势要学。
        // 代价是多占一行高度——比「找不到筛选」便宜得多。
        final chips = <Widget>[
          _chip(context, label: '全部', type: null, showCount: showChipCounts),
          for (final type in WorkType.selectable)
            _chip(
              context,
              label: type.label,
              type: type,
              showCount: showChipCounts,
            ),
          // 标签入口放在类型后面，不塞 AppBar：AppBar 已经挤了
          // 刷新 / 资讯 / 收藏 / 新番 / 年份 / 排序 / 账号七个动作，
          // 在 800px 宽的窗口下会溢出（实测 6px）。
          ActionChip(
            avatar: Icon(
              Icons.sell_outlined,
              size: 16,
              color: tags.isEmpty ? null : AppTheme.brandInk(context),
            ),
            label: Text(tags.isEmpty ? '标签' : '标签 ${tags.length}'),
            visualDensity: VisualDensity.compact,
            onPressed: onTagsPressed,
          ),
        ];

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppLayout.pagePadding,
                4,
                AppLayout.pagePadding,
                0,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Wrap(spacing: 8, runSpacing: 6, children: chips),
              ),
            ),
            Padding(
              // 右侧多留 6：视图切换自己带 2px 内边距与描边，对齐到页面边距
              // 时视觉上会比左侧文字更靠里。
              padding: const EdgeInsets.only(
                left: AppLayout.pagePadding,
                right: AppLayout.pagePadding - 6,
              ),
              child: Row(
                children: [
                  if (total != null)
                    Text(
                      _totalLabel(total!, narrow: narrow),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  const Spacer(),
                  _ViewSwitch(value: view, onChanged: onViewChanged),
                ],
              ),
            ),
            const SizedBox(height: 4),
          ],
        );
      },
    );
  }

  /// 窄屏用「万」压缩位数：`19.8 万` 比 `198100` 短一半，又不丢量级。
  /// 小数字保持 `共 3 部`——测试钉的就是这个格式。
  static String _totalLabel(int total, {required bool narrow}) {
    if (!narrow || total < 10000) return '共 $total 部';
    final wan = total / 10000;
    final text = wan >= 100 ? wan.toStringAsFixed(0) : wan.toStringAsFixed(1);
    return '共 $text 万';
  }

  Widget _chip(
    BuildContext context, {
    required String label,
    required WorkType? type,
    bool showCount = true,
  }) {
    final isSelected = selected == type;
    final count = showCount ? counts?.countOf(type) : null;

    return Padding(
      // 横向间距交给外层 Wrap 的 spacing：这里再加 right 会变成 16px 的缝。
      padding: const EdgeInsets.symmetric(vertical: 3),
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

/// 按评分排序时的说明条（W1.5 D2）。
///
/// 只在「结果里确实有无评分条目」时出现：全都有分的话这一行是废话，
/// 反而占掉列表的一屏高度。文案说的是排序规则，不是「数据缺失」——
/// 没有评分是来源站本来就有的情况（bangumi 只有 34.4% 有分），不是故障。
class _RatingSortNotice extends StatelessWidget {
  const _RatingSortNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppLayout.pagePadding + 4,
        0,
        AppLayout.pagePadding,
        0,
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 14,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '没有评分的作品排在最后',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 搜索框聚焦且为空时展开的「前置面板」：最近搜过 + 热门标签。
///
/// 这块以前只有历史。加热门标签是因为词表里那 2000 个带作品数的标签
/// 平时没人看得到——用户不知道有「机战」这种筛法，自然也不会去搜。
///
/// **点标签走的是标签筛选，不是把词填进搜索框**：`/api/works` 的 `q`
/// 只匹配标题（实测标签词「科幻」当搜索词只剩 7 条，当标签筛有 2579 条）。
/// 填进搜索框会得到「搜了个寂寞」的结果，比不给入口更糟。
///
/// **整栏包在 `Focus(descendantsAreFocusable: false)` 里**：chip 一旦能拿焦点，
/// 点它的 × 会让搜索框失焦，而这一栏的显示条件正是「搜索框聚焦」——用户点
/// 一下删除，整栏就在手指底下消失，剩下几条也没法接着删。代价是键盘 Tab
/// 到不了这些 chip，但它们本来只是鼠标/触摸的快捷方式，输入框还在最上面。
class _SearchSuggestions extends ConsumerWidget {
  const _SearchSuggestions({
    required this.queries,
    required this.hotTags,
    required this.onSelectHistory,
    required this.onSelectTag,
  });

  final List<String> queries;
  final List<TagCount> hotTags;
  final ValueChanged<String> onSelectHistory;
  final ValueChanged<String> onSelectTag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Focus(
      descendantsAreFocusable: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppLayout.pagePadding,
          8,
          AppLayout.pagePadding,
          0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (queries.isNotEmpty) ...[
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('最近搜索', style: hint),
                  for (final query in queries)
                    InputChip(
                      label: ConstrainedBox(
                        // 有人会把整句话粘进搜索框。截断而不是换行：
                        // chip 换行会把这一栏撑成好几行，把筛选栏推下去。
                        constraints: const BoxConstraints(maxWidth: 180),
                        child: Text(query, overflow: TextOverflow.ellipsis),
                      ),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => onSelectHistory(query),
                      deleteButtonTooltipMessage: '删除「$query」',
                      onDeleted: () =>
                          ref.read(searchHistoryProvider.notifier).remove(query),
                    ),
                  TextButton(
                    onPressed: () =>
                        ref.read(searchHistoryProvider.notifier).clear(),
                    child: const Text('清空'),
                  ),
                ],
              ),
              if (hotTags.isNotEmpty) const SizedBox(height: 6),
            ],
            if (hotTags.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('热门标签', style: hint),
                  for (final tag in hotTags)
                    ActionChip(
                      label: Text('${tag.name} · ${tag.count}'),
                      visualDensity: VisualDensity.compact,
                      tooltip: '按「${tag.name}」筛选作品',
                      onPressed: () => onSelectTag(tag.name),
                    ),
                ],
              ),
            const SizedBox(height: 2),
            Text(
              '搜索匹配作品标题；想按标签找，用上面的「热门标签」或筛选栏里的标签。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
