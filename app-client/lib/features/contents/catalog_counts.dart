import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/work_type.dart';
import '../../data/repositories/work_repository.dart';

/// 目录统计，只用来给筛选栏的胶囊标数量（对应站点 `.type-tab-count`）。
///
/// 数值全部取自列表接口的 `total`，**不新开接口、不改契约**：
/// `page_size=1` 拿一页就够，后端仍然是一次 `COUNT(*)`。
@immutable
class CatalogCounts {
  const CatalogCounts({required this.total, required this.byType});

  /// 全部类型的作品数。单独请求一次而不是把四类相加——
  /// 将来后端加了第五种类型，相加会悄悄少算，而这里不会。
  final int total;

  final Map<WorkType, int> byType;

  /// `null` 表示"全部"。
  int? countOf(WorkType? type) => type == null ? total : byType[type];
}

/// 一次会话只查一次：目录规模不会秒级变化，筛选/翻页时重复拉纯属浪费。
///
/// 失败一律降级成"没有角标"（页面用 `valueOrNull` 取）——数量只是辅助信息，
/// 不能因为它挂了就让整个列表报错。
///
/// 关掉自动重试：Riverpod 3 默认会重试 10 次（200ms→6400ms 退避），而这一项
/// 每次要并发打 5 个请求。断网时那等于 50 次无效请求打自家后端，而且失败期间
/// 页面会一直转圈——角标是辅助信息，失败就该立刻消失，不该拖着整个列表等它。
final catalogCountsProvider = FutureProvider<CatalogCounts>((ref) async {
  final repository = ref.watch(workRepositoryProvider);

  // 五个请求并发：打的是自家后端，不受来源站 ≤2 并发/1–2 req/s 的约束。
  final results = await Future.wait([
    repository.fetchWorks(page: 1, pageSize: 1),
    for (final type in WorkType.selectable)
      repository.fetchWorks(type: type, page: 1, pageSize: 1),
  ]);

  return CatalogCounts(
    total: results.first.value.total,
    byType: {
      for (var i = 0; i < WorkType.selectable.length; i++)
        WorkType.selectable[i]: results[i + 1].value.total,
    },
  );
}, retry: (retryCount, error) => null);
