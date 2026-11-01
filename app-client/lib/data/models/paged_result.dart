import 'package:flutter/foundation.dart';

/// 分页容器。字段名与契约 6.1 的响应一致：
/// `{total, page, page_size, total_pages, items}`。
@immutable
class PagedResult<T> {
  const PagedResult({
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
    required this.totalPages,
    this.hidden,
  });

  final List<T> items;
  final int total;
  final int page;
  final int pageSize;

  /// 契约 6.1：`page` 超过 `total_pages` 时服务端返回空 `items`，
  /// 客户端据此判断"没有更多"，不要用 HTTP 状态判断。
  final int totalPages;

  /// 当前筛选条件下、因为内容策略被隐藏的条数。
  ///
  /// **只有作品列表会给**（`WorkPaging.hidden`）。`null` 与 `0` 语义不同：
  /// - `null`：这个接口没有这个概念（资讯、收藏等），别显示「已隐藏 0 部」；
  /// - `0`：确实一条都没藏。
  final int? hidden;

  bool get hasNext => page < totalPages;

  bool get isEmpty => items.isEmpty;

  factory PagedResult.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic> json) itemFromJson, {
    int fallbackPageSize = 20,
  }) {
    final pageSize = _asInt(json['page_size'], fallbackPageSize);
    final page = _asInt(json['page'], 1);

    final items = <T>[];
    final rawItems = json['items'];
    if (rawItems is List) {
      for (final raw in rawItems) {
        if (raw is! Map) continue;
        try {
          items.add(itemFromJson(Map<String, dynamic>.from(raw)));
        } on FormatException catch (error) {
          // 单条坏数据不该让整页白屏，跳过并留下日志便于排查。
          debugPrint('[PagedResult] 跳过一条无法解析的数据: $error');
        }
      }
    }

    final total = _asInt(json['total'], items.length);
    final totalPages = _asInt(
      json['total_pages'],
      pageSize > 0 ? (total / pageSize).ceil() : 0,
    );
    // 缺失就是缺失，别补 0：见字段注释里 null 与 0 的区别。
    final rawHidden = json['hidden'];

    return PagedResult<T>(
      items: items,
      total: total,
      page: page,
      pageSize: pageSize,
      totalPages: totalPages,
      hidden: rawHidden is num ? rawHidden.toInt() : null,
    );
  }

  /// 序列化。离线缓存用（见 `HiveWorkCache`）。
  ///
  /// 与 [fromJson] 对称：分页元信息（`total` / `total_pages`）必须一起存，
  /// 少存了 `total_pages` 的话，翻页条会以为还有下一页，一直滚到底。
  Map<String, dynamic> toJson(
    Map<String, dynamic> Function(T) itemToJson,
  ) {
    return {
      'total': total,
      'page': page,
      'page_size': pageSize,
      'total_pages': totalPages,
      'items': [for (final item in items) itemToJson(item)],
      // 只有非空才写：null 表示「这个接口没这个概念」，存成 null 会让离线时
      // 看起来像「藏了 0 部」。
      if (hidden != null) 'hidden': hidden,
    };
  }

  static int _asInt(Object? raw, int fallback) => switch (raw) {
    final num n => n.toInt(),
    final String s => int.tryParse(s) ?? fallback,
    _ => fallback,
  };

  @override
  String toString() =>
      'PagedResult(page: $page/$totalPages, items: ${items.length}, total: $total)';
}
