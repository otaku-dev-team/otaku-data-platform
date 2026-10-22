import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../models/paged_result.dart';
import '../models/related_works.dart';
import '../models/work.dart';
import '../models/work_sort.dart';
import '../models/work_summary.dart';
import '../models/work_type.dart';
import 'work_data_source.dart';

/// 后端未就绪时的本地数据源。数据来自 `assets/mock/`：
///
/// - `works_catalog.json`：列表全量（24 条），筛选与分页在这里本地模拟；
/// - `works_details.json`：`work_id → 详情`，含超长简介、空标签、无评分等边界。
///
/// 它刻意保留了服务端的语义（过滤、分页、404），这样切换到真接口时
/// 页面行为不会突变。
class MockWorkDataSource implements WorkDataSource {
  MockWorkDataSource({
    AssetBundle? bundle,
    this.latency = const Duration(milliseconds: 320),
  }) : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;

  /// 模拟网络耗时，用来验证加载态与骨架屏。测试里传 [Duration.zero]。
  final Duration latency;

  List<WorkSummary>? _catalog;
  Map<String, dynamic>? _details;

  static const String _catalogAsset = 'assets/mock/works_catalog.json';
  static const String _detailsAsset = 'assets/mock/works_details.json';

  Future<List<WorkSummary>> _loadCatalog() async {
    final cached = _catalog;
    if (cached != null) return cached;

    final raw = await _bundle.loadString(_catalogAsset);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final catalog = PagedResult<WorkSummary>.fromJson(
      json,
      WorkSummary.fromJson,
    ).items;
    _catalog = catalog;
    return catalog;
  }

  Future<Map<String, dynamic>> _loadDetails() async {
    final cached = _details;
    if (cached != null) return cached;

    final raw = await _bundle.loadString(_detailsAsset);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    _details = json;
    return json;
  }

  @override
  Future<PagedResult<WorkSummary>> fetchWorks({
    WorkType? type,
    String? query,
    WorkSort sort = WorkSort.id,
    int page = 1,
    int pageSize = AppConfig.pageSize,
  }) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);

    final catalog = await _loadCatalog();
    final keyword = query?.trim().toLowerCase() ?? '';
    final filtered = catalog.where((work) {
      if (type != null && type != WorkType.unknown && work.workType != type) {
        return false;
      }
      // 契约 6.1：`q` 只匹配标题子串、忽略大小写。
      if (keyword.isNotEmpty && !work.title.toLowerCase().contains(keyword)) {
        return false;
      }
      return true;
    }).toList(growable: false);

    // 排序必须在过滤之后、分页之前：分页切的是排序后的序列，
    // 否则「第二页」会把排序前的旧顺序混进来。
    final ordered = _applySort(filtered, sort);

    final size = pageSize.clamp(1, AppConfig.maxPageSize);
    final total = ordered.length;
    final totalPages = total == 0 ? 0 : (total + size - 1) ~/ size;
    final start = (page - 1) * size;
    final items = start >= total
        ? const <WorkSummary>[]
        : ordered.sublist(start, math.min(start + size, total));

    return PagedResult<WorkSummary>(
      items: items,
      total: total,
      page: page,
      pageSize: size,
      totalPages: totalPages,
    );
  }

  /// 与服务端同一套顺序：降序在前、`null` 沉底、`work_id` 作次级键。
  ///
  /// 次级键不是可选项：Dart 的 `sort` 不保证稳定，同一条数据两次排序可能
  /// 换位置，翻页时就会看到重复或漏条——服务端也是用 `id` 兜底的。
  List<WorkSummary> _applySort(List<WorkSummary> source, WorkSort sort) {
    if (sort == WorkSort.id) return source; // Mock 的 catalog 顺序即入库顺序

    final items = List<WorkSummary>.of(source);
    int compare(WorkSummary a, WorkSummary b) {
      final av = sort == WorkSort.rating
          ? a.mainRating?.value
          : a.releaseYear?.toDouble();
      final bv = sort == WorkSort.rating
          ? b.mainRating?.value
          : b.releaseYear?.toDouble();
      // 一方无值：有值的在前（null 沉底）。
      if (av == null || bv == null) {
        if (av == null && bv == null) return a.workId.compareTo(b.workId);
        return av == null ? 1 : -1;
      }
      final byValue = bv.compareTo(av); // 降序
      return byValue != 0 ? byValue : a.workId.compareTo(b.workId);
    }

    items.sort(compare);
    return items;
  }

  @override
  Future<Work> fetchDetail(String workId) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);

    final details = await _loadDetails();
    final item = details[workId];
    if (item is! Map) {
      // 与契约 6.2 一致：不存在就是 404，客户端提示后返回列表。
      throw const ApiException(
        code: ApiErrorCode.workNotFound,
        message: '作品不存在',
        statusCode: 404,
      );
    }
    return Work.fromJson(Map<String, dynamic>.from(item));
  }

  @override
  Future<RelatedWorks> fetchRelated(String workId, {int limit = 6}) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);

    final catalog = await _loadCatalog();
    WorkSummary? target;
    for (final work in catalog) {
      if (work.workId == workId) {
        target = work;
        break;
      }
    }
    // 契约：作品不存在 = 404；这里与 fetchDetail 保持一致。
    if (target == null) {
      throw const ApiException(
        code: ApiErrorCode.workNotFound,
        message: '作品不存在',
        statusCode: 404,
      );
    }

    final tags = target.tags;
    // 契约：作品没有标签 → 空结果，不是错误。
    if (tags == null || tags.isEmpty) return const RelatedWorks(basisTags: [], items: []);

    final basisTags = tags.take(5).toList(growable: false);
    final candidates = <WorkSummary>[];
    for (final work in catalog) {
      if (work.workId == workId) continue; // 不返回自己
      final own = work.tags;
      if (own == null) continue;
      if (!own.any(tags.contains)) continue;
      candidates.add(work);
    }

    // 与服务端一致：评分高 → 低，无评分排最后。
    final ordered = _applySort(candidates, WorkSort.rating);
    return RelatedWorks(
      basisTags: basisTags,
      items: ordered.take(limit.clamp(1, 20)).toList(growable: false),
    );
  }
}
