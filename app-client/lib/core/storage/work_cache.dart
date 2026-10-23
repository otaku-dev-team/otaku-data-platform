import 'package:flutter/foundation.dart';

import '../../data/models/related_works.dart';
import '../../data/models/work.dart';
import '../../data/models/work_sort.dart';
import '../../data/models/work_summary.dart';
import '../../data/models/work_type.dart';

/// 离线缓存里的一条记录。
///
/// **为什么必须带时间戳**：铁律 3 要求「后端不可达时展示缓存 + 标注上次同步」。
/// 没有时间戳就没法标注，用户会以为看到的是最新数据——那比直接报错更糟，
/// 因为它让用户基于过期信息做判断。
@immutable
class CachedEntry<T> {
  const CachedEntry({required this.value, required this.cachedAt});

  final T value;

  /// 这条缓存是什么时候从服务端拿到的。
  final DateTime cachedAt;

  @override
  String toString() => 'CachedEntry(cachedAt: $cachedAt)';
}

/// 列表页的缓存键。
///
/// 列表的每一页都是一次独立请求的结果，缓存要能按
/// 「类型 + 关键词 + 排序 + 页码 + 每页条数」精确取回。
/// 少一个维度就会取错页——比如把「按评分排序的第 1 页」当成
/// 「按入库顺序的第 1 页」返回，用户会看到完全对不上的内容。
///
/// **每页条数也在键里**：目录统计用 `page_size=1` 只取一个来读 `total`，
/// 它和列表页的 `page_size=50` 是两个不同的请求，共用一个键的话，
/// 统计请求会把列表那一页的缓存覆盖成只剩一条。
@immutable
class ListCacheKey {
  const ListCacheKey({
    required this.type,
    required this.query,
    required this.sort,
    required this.page,
    this.pageSize = 50,
    this.tag,
  });

  final WorkType? type;

  /// 已归一（trim）的关键词。空串与 null 等价。
  final String query;

  final WorkSort sort;
  final int page;

  /// 每页条数。参与键的计算，理由见类注释。
  final int pageSize;

  /// 标签筛选（契约 `GET /api/works?tag=`，精确匹配整个标签）。
  ///
  /// **必须参与键的计算**：少了它，「按科幻筛的第一页」与「不筛标签的第一页」
  /// 共用一个键，离线时按标签打开列表会拿到根本没筛过的内容，
  /// 而界面上看不出任何异常——这是最坏的一类缓存 bug。
  final String? tag;

  /// 归一后的标签：空串与 null 是同一个意思（都表示不过滤）。
  String get normalizedTag => tag?.trim() ?? '';

  /// 归一后的关键词：null 与空串是同一个意思。
  String get normalizedQuery => query.trim();

  /// 拼成缓存的键。分隔符用 unlikely 字符（`\u0000`），
  /// 关键词里出现它的概率极低——真出现了也只是这条缓存取不中，
  /// 不会串到别的键上。
  String get storageKey {
    final parts = [
      type?.value ?? '',
      normalizedQuery,
      sort.value,
      '$page',
      '$pageSize',
      normalizedTag,
    ];
    return 'list:${parts.join('\u0000')}';
  }

  @override
  bool operator ==(Object other) =>
      other is ListCacheKey &&
      other.type == type &&
      other.normalizedQuery == normalizedQuery &&
      other.sort == sort &&
      other.page == page &&
      other.pageSize == pageSize &&
      other.normalizedTag == normalizedTag;

  @override
  int get hashCode =>
      Object.hash(type, normalizedQuery, sort, page, pageSize, normalizedTag);

  @override
  String toString() => 'ListCacheKey($storageKey)';
}

/// 缓存里的一页列表。
///
/// **连分页元信息一起存**：`total` 与 `total_pages` 不存的话，
/// 离线回退时不知道库里还有多少，翻页条会以为到底了或一直有下一页。
/// 目录统计（`page_size=1` 只为读 `total`）也依赖这个值。
@immutable
class CachedListPage {
  const CachedListPage({
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
    required this.totalPages,
  });

  final List<WorkSummary> items;
  final int total;
  final int page;
  final int pageSize;
  final int totalPages;

  @override
  String toString() =>
      'CachedListPage(page: $page/$totalPages, items: ${items.length})';
}

/// 作品详情的缓存键。
@immutable
class DetailCacheKey {
  const DetailCacheKey(this.workId);

  final String workId;

  String get storageKey => 'detail:$workId';

  @override
  bool operator ==(Object other) =>
      other is DetailCacheKey && other.workId == workId;

  @override
  int get hashCode => workId.hashCode;

  @override
  String toString() => 'DetailCacheKey($workId)';
}

/// 同标签推荐的缓存键。
@immutable
class RelatedCacheKey {
  const RelatedCacheKey(this.workId);

  final String workId;

  String get storageKey => 'related:$workId';

  @override
  bool operator ==(Object other) =>
      other is RelatedCacheKey && other.workId == workId;

  @override
  int get hashCode => workId.hashCode;

  @override
  String toString() => 'RelatedCacheKey($workId)';
}

/// 作品数据的本地缓存。
///
/// **只缓存「平台（Java）已返回」的响应**——铁律 1。
/// 客户端**绝不**直接连来源站：来源站只读、不代持凭据、不抓登录后内容，
/// 离线缓存同样不能成为「绕过平台直连来源站」的后门。
///
/// 分成列表 / 详情 / 推荐三类，是因为它们的生命周期不同：
/// - 列表按「条件 + 页码」缓存，用户换个筛选条件就换一批；
/// - 详情按 `work_id` 缓存，一件作品打开过就一直可看；
/// - 推荐按 `work_id` 缓存，是详情页的补充区块，优先级最低。
///
/// 抽象成接口而不是直接用 Hive，是沿用 [TokenStore] 的分层范式：
/// 单测里换内存实现，不依赖平台通道。
abstract interface class WorkCache {
  /// 读列表页缓存。没有缓存返回 `null`。
  Future<CachedEntry<CachedListPage>?> readList(ListCacheKey key);

  /// 写列表页缓存。
  Future<void> writeList(ListCacheKey key, CachedListPage page);

  /// 读详情缓存。
  Future<CachedEntry<Work>?> readDetail(DetailCacheKey key);

  /// 写详情缓存。
  Future<void> writeDetail(DetailCacheKey key, Work work);

  /// 读推荐缓存。
  Future<CachedEntry<RelatedWorks>?> readRelated(RelatedCacheKey key);

  /// 写推荐缓存。
  Future<void> writeRelated(RelatedCacheKey key, RelatedWorks related);

  /// 清空全部缓存。退出登录时调用——缓存里是上一个账号看过的内容。
  Future<void> clear();
}
