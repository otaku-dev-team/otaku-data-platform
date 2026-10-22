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
  const ContentsFilter({this.type, this.query = '', this.sort = WorkSort.id});

  final WorkType? type;
  final String query;

  /// 排序。它和类型/关键词是同一层的条件：变了就得重新查第一页，
  /// 只改本地顺序是不行的——服务端手里才有全量数据。
  final WorkSort sort;

  @override
  bool operator ==(Object other) =>
      other is ContentsFilter &&
      other.type == type &&
      other.query == query &&
      other.sort == sort;

  @override
  int get hashCode => Object.hash(type, query, sort);
}

class ContentsFilterController extends Notifier<ContentsFilter> {
  @override
  ContentsFilter build() => const ContentsFilter();

  /// 传 `null` 表示"全部类型"。
  void selectType(WorkType? type) {
    if (state.type == type) return;
    state = ContentsFilter(type: type, query: state.query, sort: state.sort);
  }

  void search(String query) {
    final normalized = query.trim();
    if (normalized == state.query) return;
    state = ContentsFilter(type: state.type, query: normalized, sort: state.sort);
  }

  void selectSort(WorkSort sort) {
    if (state.sort == sort) return;
    state = ContentsFilter(type: state.type, query: state.query, sort: sort);
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
