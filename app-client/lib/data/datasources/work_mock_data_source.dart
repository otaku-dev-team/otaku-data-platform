import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../models/paged_result.dart';
import '../models/work.dart';
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

    final size = pageSize.clamp(1, AppConfig.maxPageSize);
    final total = filtered.length;
    final totalPages = total == 0 ? 0 : (total + size - 1) ~/ size;
    final start = (page - 1) * size;
    final items = start >= total
        ? const <WorkSummary>[]
        : filtered.sublist(start, math.min(start + size, total));

    return PagedResult<WorkSummary>(
      items: items,
      total: total,
      page: page,
      pageSize: size,
      totalPages: totalPages,
    );
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
}
