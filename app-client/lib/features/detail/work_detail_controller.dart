import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/work.dart';
import '../../data/repositories/work_repository.dart';

/// 详情按 `work_id` 单独缓存一页。`work_id` 是不透明字符串，直接当 family 的 key。
///
/// 显式关掉 Riverpod 3 的自动重试：契约 6.2 要求 404 提示后返回列表、
/// **不自动重试**；断网也需要让用户看到明确错误，而不是无限转圈。
final workDetailProvider = FutureProvider.family<Work, String>(
  (ref, workId) {
    return ref.watch(workRepositoryProvider).fetchDetail(workId);
  },
  retry: (retryCount, error) => null,
);
