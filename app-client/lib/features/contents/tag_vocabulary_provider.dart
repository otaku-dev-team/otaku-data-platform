import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/network/dio_client.dart';
import '../../data/datasources/tag_data_source.dart';
import '../../data/datasources/tag_mock_data_source.dart';
import '../../data/datasources/tag_remote_data_source.dart';
import '../../data/models/tag_vocabulary.dart';
import '../../data/models/work_type.dart';

/// 词表走哪一路，与作品数据同一个开关（`AppConfig.useMock`）。
final tagDataSourceProvider = Provider<TagDataSource>((ref) {
  if (AppConfig.useMock) return MockTagDataSource();
  return RemoteTagDataSource(ref.watch(dioProvider));
});

/// 标签词表，按作品类型分桶（`type` 为 null = 全部类型）。
///
/// **why family**：当前筛的是「动画」时，面板里不该出现只有游戏才用的标签——
/// 点了它结果必然是 0 条。后端 `/api/tags?type=` 本来就支持，前端没接而已。
///
/// **刻意不 autoDispose**：面板关了再开不该重新请求一次——词表变化很慢
/// （只有导入跑完才会变），而每次打开面板都打一次 `/api/tags` 是在给
/// 限流添砖。需要刷新时 `ref.invalidate(tagVocabularyProvider(type))`。
///
/// ⚠️ `retry` 必须显式关掉：Riverpod 3 的默认重试是 200ms→6400ms 的退避，
/// 断网时面板会卡在 loading 十几秒而不是立刻给错误态。
final tagVocabularyProvider =
    FutureProvider.family<TagVocabulary, WorkType?>((ref, type) async {
      final source = ref.watch(tagDataSourceProvider);
      return source.fetchTags(type: type);
    }, retry: (retryCount, error) => null);

/// 搜索前置面板里的「热门标签」：词表里作品数最多的若干个。
///
/// **为什么不让用户直接搜标签名**：`/api/works` 的 `q` 只匹配标题
/// （实测「科幻」当搜索词只有 7 条，而当标签筛有 2579 条）。所以这里点
/// 标签走的是**标签筛选**，不是往搜索框里填字——填进去等于骗他。
///
/// 取 12 个：再多人就只是把一块 chip 墙搬到了搜索框下面。
final hotTagSuggestionsProvider = FutureProvider<List<TagCount>>((ref) async {
  final vocabulary = await ref.watch(tagVocabularyProvider(null).future);
  final sorted = [...vocabulary.items]
    ..sort((a, b) => b.count.compareTo(a.count));
  return sorted.take(hotTagSuggestionCount).toList(growable: false);
}, retry: (retryCount, error) => null);

/// 搜索前置面板里显示几个热门标签。
const int hotTagSuggestionCount = 12;
