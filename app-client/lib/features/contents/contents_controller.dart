import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../data/models/work_sort.dart';
import '../../data/models/work_summary.dart';
import '../../data/models/work_type.dart';
import '../../data/repositories/work_repository.dart';

/// 列表的查询条件。类型、关键词、排序都放在这里，控制器通过 watch 它来重新加载。
@immutable
class ContentsFilter {
  const ContentsFilter({
    this.type,
    this.query = '',
    this.sort = WorkSort.id,
    this.tag,
  });

  final WorkType? type;
  final String query;

  /// 标签筛选（契约 `tag=`）。`null` 表示不过滤。
  ///
  /// 与 [type] / [query] / [sort] 是同一层的条件：变了就得重新查第一页，
  /// 只筛本地列表是错的——服务端手里才有全量数据。
  final String? tag;

  /// 排序。它和类型/关键词是同一层的条件：变了就得重新查第一页，
  /// 只改本地顺序是不行的——服务端手里才有全量数据。
  final WorkSort sort;

  @override
  bool operator ==(Object other) =>
      other is ContentsFilter &&
      other.type == type &&
      other.query == query &&
      other.sort == sort &&
      other.tag == tag;

  @override
  int get hashCode => Object.hash(type, query, sort, tag);
}

class ContentsFilterController extends Notifier<ContentsFilter> {
  @override
  ContentsFilter build() => const ContentsFilter();

  /// 传 `null` 表示"全部类型"。
  void selectType(WorkType? type) {
    if (state.type == type) return;
    // 同 search：其余条件要一起带走，别把已选的标签丢掉。
    state = ContentsFilter(
      type: type,
      query: state.query,
      sort: state.sort,
      tag: state.tag,
    );
  }

  void search(String query) {
    final normalized = query.trim();
    if (normalized == state.query) return;
    // 标签必须一起带走：换筛选条件的语义是「保持其余条件、只改这一个」，
    // 漏掉 tag 的话，用户先选标签再搜索会把标签静默清掉——
    // 而界面上的筛选条会跟着消失，用户只会觉得「标签筛没了」。
    state = ContentsFilter(
      type: state.type,
      query: normalized,
      sort: state.sort,
      tag: state.tag,
    );
  }

  void selectSort(WorkSort sort) {
    if (state.sort == sort) return;
    state = ContentsFilter(
      type: state.type,
      query: state.query,
      sort: sort,
      tag: state.tag,
    );
  }

  /// 从首页「分类浏览」进来：**只保留类型**，清掉搜索 / 标签 / 排序。
  ///
  /// 不能直接调 [selectType]：它的语义是「保持其余条件、只改类型」。
  /// 从首页进来时用户看到的是一条干净的分栏入口，如果残留着上次的标签
  /// 或搜索词，结果会莫名其妙只剩几条，而首页上没有任何线索能解释为什么。
  void showType(WorkType? type) {
    if (state.type == type &&
        state.query.isEmpty &&
        state.tag == null &&
        state.sort == WorkSort.id) {
      return;
    }
    state = ContentsFilter(type: type);
  }

  /// 从首页「高分作品 · 查看全部」进来：按评分排序，其余条件清零。
  void showTopRated() {
    if (state.sort == WorkSort.rating &&
        state.type == null &&
        state.query.isEmpty &&
        state.tag == null) {
      return;
    }
    state = const ContentsFilter(sort: WorkSort.rating);
  }

  /// 按标签筛选。传 `null` 或空串表示取消筛选（点已选中的标签、或点清除）。
  void selectTag(String? tag) {
    final trimmed = tag?.trim();
    final next = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    if (next == state.tag) return;
    state = ContentsFilter(
      type: state.type,
      query: state.query,
      sort: state.sort,
      tag: next,
    );
  }

  /// 从详情页点标签进来：**只保留标签**，清掉类型 / 搜索 / 排序。
  ///
  /// 与 [selectTag] 的区别在语义：selectTag 是「在当前条件下换一个标签」，
  /// 而从详情页跳进来时，用户脑子里只有「这个标签还有什么」——如果列表里
  /// 还残留着上次的分类或关键词，结果会莫名其妙只剩几条，而详情页上
  /// 没有任何线索能解释为什么少了。
  void showTag(String tag) {
    final trimmed = tag.trim();
    if (trimmed.isEmpty) return;
    if (state.tag == trimmed &&
        state.type == null &&
        state.query.isEmpty &&
        state.sort == WorkSort.id) {
      return;
    }
    state = ContentsFilter(tag: trimmed);
  }

  /// 清掉全部筛选条件（类型 / 关键词 / 标签），**保留排序**。
  ///
  /// 排序不是筛选：用户选「按评分」是想看到顺序，不是想少看内容；
  /// 清筛选时把它一起重置，会让他觉得排序也莫名其妙丢了。
  void clearFilters() {
    if (state.type == null && state.query.isEmpty && state.tag == null) return;
    state = ContentsFilter(sort: state.sort);
  }
}

final contentsFilterProvider =
    NotifierProvider<ContentsFilterController, ContentsFilter>(
      ContentsFilterController.new,
    );

/// 列表页的完整状态：已加载的数据 + 分页进度 + 加载更多的失败信息。
///
/// 首屏错误走 [AsyncError]，分页错误走 [loadMoreError]——两者必须分开，
/// 否则加载下一页失败会把已经看到的内容清空。
@immutable
class ContentsData {
  const ContentsData({
    required this.filter,
    required this.items,
    required this.page,
    required this.total,
    required this.totalPages,
    this.isLoadingMore = false,
    this.loadMoreError,
    this.fromCache = false,
    this.cachedAt,
  });

  /// 这份数据是用哪组条件查出来的。
  ///
  /// 换条件后 Riverpod 会把旧数据带进新的 AsyncLoading/AsyncError，
  /// 界面据此判断"看到的内容是不是当前条件的"，避免把上一组结果当成新结果。
  final ContentsFilter filter;

  final List<WorkSummary> items;
  final int page;
  final int total;
  final int totalPages;
  final bool isLoadingMore;
  final ApiException? loadMoreError;

  /// 当前展示的内容是不是来自离线缓存。
  ///
  /// 为 true 时界面**必须**提示「上次同步」，否则用户会把缓存当成最新数据。
  final bool fromCache;

  /// 缓存写入时刻。只有 [fromCache] 为 true 时才有值。
  final DateTime? cachedAt;

  bool get hasMore => page < totalPages;

  ContentsData copyWith({
    List<WorkSummary>? items,
    int? page,
    int? total,
    int? totalPages,
    bool? isLoadingMore,
    ApiException? loadMoreError,
    bool clearLoadMoreError = false,
    bool? fromCache,
    DateTime? cachedAt,
  }) {
    return ContentsData(
      filter: filter,
      items: items ?? this.items,
      page: page ?? this.page,
      total: total ?? this.total,
      totalPages: totalPages ?? this.totalPages,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      loadMoreError: clearLoadMoreError
          ? null
          : (loadMoreError ?? this.loadMoreError),
      fromCache: fromCache ?? this.fromCache,
      cachedAt: cachedAt ?? this.cachedAt,
    );
  }
}

class ContentsController extends AsyncNotifier<ContentsData> {
  @override
  Future<ContentsData> build() async {
    // 条件变化时 build 会重跑，等于自动重新查询第一页。
    final filter = ref.watch(contentsFilterProvider);
    final fetched = await ref.watch(workRepositoryProvider).fetchWorks(
      type: filter.type,
      query: filter.query,
      sort: filter.sort,
      page: 1,
      tag: filter.tag,
    );
    final result = fetched.value;

    return ContentsData(
      filter: filter,
      items: result.items,
      page: result.page,
      total: result.total,
      totalPages: result.totalPages,
      fromCache: fetched.fromCache,
      cachedAt: fetched.cachedAt,
    );
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || current.isLoadingMore || !current.hasMore) return;

    state = AsyncData(
      current.copyWith(isLoadingMore: true, clearLoadMoreError: true),
    );

    final filter = ref.read(contentsFilterProvider);
    try {
      final fetched = await ref.read(workRepositoryProvider).fetchWorks(
        type: filter.type,
        query: filter.query,
        // 翻页必须带同一 sort：不带就退回默认顺序，第 2 页会和
        // 第 1 页接不上（重复或漏条）。
        sort: filter.sort,
        page: current.page + 1,
        tag: filter.tag,
      );
      final next = fetched.value;

      // 请求返回时条件可能已经变了，过期结果直接丢弃。
      if (!ref.mounted || ref.read(contentsFilterProvider) != filter) return;

      state = AsyncData(
        current.copyWith(
          items: [...current.items, ...next.items],
          page: next.page,
          total: next.total,
          totalPages: next.totalPages,
          isLoadingMore: false,
          clearLoadMoreError: true,
          // 这一页来自缓存，整份列表就都是缓存内容了——标注跟着更新，
          // 别让用户以为新追加的几条是最新的。
          fromCache: current.fromCache || fetched.fromCache,
          cachedAt: fetched.cachedAt ?? current.cachedAt,
        ),
      );
    } on ApiException catch (error) {
      if (!ref.mounted) return;
      state = AsyncData(
        current.copyWith(isLoadingMore: false, loadMoreError: error),
      );
    }
  }

  /// 下拉刷新 / 重试。错误由 state 呈现，这里只负责让下拉动画结束。
  Future<void> refresh() async {
    ref.invalidateSelf();
    try {
      await future;
    } on Object {
      // 忽略：build 抛出的异常已经变成 AsyncError 了。
    }
  }
}

final contentsControllerProvider =
    AsyncNotifierProvider<ContentsController, ContentsData>(
      ContentsController.new,
      // 契约要求错误必须显式呈现；自动重试会让失败看起来像"一直在加载"。
      retry: (retryCount, error) => null,
    );
