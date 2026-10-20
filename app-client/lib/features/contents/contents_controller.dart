import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../data/models/work_summary.dart';
import '../../data/models/work_type.dart';
import '../../data/repositories/work_repository.dart';

/// 列表的查询条件。类型与关键词都放在这里，控制器通过 watch 它来重新加载。
@immutable
class ContentsFilter {
  const ContentsFilter({this.type, this.query = ''});

  final WorkType? type;
  final String query;

  @override
  bool operator ==(Object other) =>
      other is ContentsFilter && other.type == type && other.query == query;

  @override
  int get hashCode => Object.hash(type, query);
}

class ContentsFilterController extends Notifier<ContentsFilter> {
  @override
  ContentsFilter build() => const ContentsFilter();

  /// 传 `null` 表示"全部类型"。
  void selectType(WorkType? type) {
    if (state.type == type) return;
    state = ContentsFilter(type: type, query: state.query);
  }

  void search(String query) {
    final normalized = query.trim();
    if (normalized == state.query) return;
    state = ContentsFilter(type: state.type, query: normalized);
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

  bool get hasMore => page < totalPages;

  ContentsData copyWith({
    List<WorkSummary>? items,
    int? page,
    int? total,
    int? totalPages,
    bool? isLoadingMore,
    ApiException? loadMoreError,
    bool clearLoadMoreError = false,
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
    );
  }
}

class ContentsController extends AsyncNotifier<ContentsData> {
  @override
  Future<ContentsData> build() async {
    // 条件变化时 build 会重跑，等于自动重新查询第一页。
    final filter = ref.watch(contentsFilterProvider);
    final result = await ref
        .watch(workRepositoryProvider)
        .fetchWorks(type: filter.type, query: filter.query, page: 1);

    return ContentsData(
      filter: filter,
      items: result.items,
      page: result.page,
      total: result.total,
      totalPages: result.totalPages,
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
      final next = await ref
          .read(workRepositoryProvider)
          .fetchWorks(type: filter.type, query: filter.query, page: current.page + 1);

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
