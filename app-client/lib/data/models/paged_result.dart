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
  });

  final List<T> items;
  final int total;
  final int page;
  final int pageSize;

  /// 契约 6.1：`page` 超过 `total_pages` 时服务端返回空 `items`，
  /// 客户端据此判断"没有更多"，不要用 HTTP 状态判断。
  final int totalPages;

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

    return PagedResult<T>(
      items: items,
      total: total,
      page: page,
      pageSize: pageSize,
      totalPages: totalPages,
    );
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
