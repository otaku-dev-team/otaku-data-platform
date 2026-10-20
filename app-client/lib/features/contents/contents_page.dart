import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../../core/theme/app_layout.dart';
import '../../data/models/work_summary.dart';
import '../../data/models/work_type.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/error_state.dart';
import '../../shared/widgets/skeleton_list.dart';
import 'contents_controller.dart';
import 'work_card.dart';

/// 作品列表：搜索 + 类型筛选 + 无限滚动分页。
///
/// 状态矩阵（验收时逐条对）：
/// - 首屏加载 → 骨架屏
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

  void _clearQuery() {
    _debounce?.cancel();
    _searchController.clear();
    ref.read(contentsFilterProvider.notifier).search('');
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(contentsFilterProvider);
    final contents = ref.watch(contentsControllerProvider);

    ref.listen<ContentsFilter>(contentsFilterProvider, (previous, next) {
      if (previous == null || previous == next) return;
      _requestScrollReset();
    });

    return Scaffold(
      appBar: AppBar(title: const Text('作品库')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppLayout.listMaxWidth),
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
              _TypeFilters(
                selected: filter.type,
                onSelected: (type) =>
                    ref.read(contentsFilterProvider.notifier).selectType(type),
              ),
              Expanded(child: _buildBody(filter, contents)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ContentsFilter filter, AsyncValue<ContentsData> contents) {
    final data = contents.value;
    // 换条件后 Riverpod 会把上一组数据保留在 AsyncLoading/AsyncError 里，
    // 那份数据不属于当前条件，不能当结果展示。
    final isStale = data != null && data.filter != filter;

    if (contents.isLoading && (data == null || isStale)) {
      return const SkeletonList();
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
          Expanded(child: _buildList(data)),
        ],
      );
    }

    final resolved = contents.requireValue;
    if (resolved.items.isEmpty) return _buildEmpty(filter);
    return _buildList(resolved);
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

  Widget _buildList(ContentsData data) {
    _flushScrollReset();
    return RefreshIndicator(
      onRefresh: () => ref.read(contentsControllerProvider.notifier).refresh(),
      child: ListView.separated(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppLayout.pagePadding,
          8,
          AppLayout.pagePadding,
          24,
        ),
        itemCount: data.items.length + 1,
        separatorBuilder: (context, index) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          if (index == data.items.length) return _buildFooter(data);
          return _buildCard(data.items[index]);
        },
      ),
    );
  }

  Widget _buildCard(WorkSummary work) => WorkCard(work: work);

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

class _TypeFilters extends StatelessWidget {
  const _TypeFilters({required this.selected, required this.onSelected});

  final WorkType? selected;
  final ValueChanged<WorkType?> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: AppLayout.pagePadding,
          vertical: 8,
        ),
        children: [
          _chip(context, label: '全部', type: null),
          for (final type in WorkType.selectable)
            _chip(context, label: type.label, type: type),
        ],
      ),
    );
  }

  Widget _chip(
    BuildContext context, {
    required String label,
    required WorkType? type,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected == type,
        onSelected: (_) => onSelected(type),
        visualDensity: VisualDensity.compact,
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
