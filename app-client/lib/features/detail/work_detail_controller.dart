import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/related_works.dart';
import '../../data/models/work.dart';
import '../../data/repositories/work_repository.dart';

/// 详情按 `work_id` 单独缓存一页。`work_id` 是不透明字符串，直接当 family 的 key。
///
/// 显式关掉 Riverpod 3 的自动重试：契约 6.2 要求 404 提示后返回列表、
/// **不自动重试**；断网也需要让用户看到明确错误，而不是无限转圈。
///
/// 返回 [Fetched] 而不是裸的 [Work]：离线回退时界面要能区分
/// 「这是最新数据」和「这是上次同步的缓存」。不区分的话，用户会把
/// 缓存当成最新数据来读——那比直接报错更糟（铁律 3）。
final workDetailProvider = FutureProvider.family<Fetched<Work>, String>((
  ref,
  workId,
) {
  return ref.watch(workRepositoryProvider).fetchDetail(workId);
}, retry: (retryCount, error) => null);

/// 同标签推荐，按 `work_id` 单独缓存。
///
/// 与详情**分开**是一个刻意的选择：推荐拿不到时详情页照常显示，
/// 两者的加载与失败互不影响（区块见 [RelatedWorksSection]）。
/// 同样关掉自动重试：拿不到就不显示这一块，没必要在后台一直重试。
final relatedWorksProvider = FutureProvider.family<Fetched<RelatedWorks>, String>(
  (ref, workId) {
    return ref.watch(workRepositoryProvider).fetchRelated(workId);
  },
  retry: (retryCount, error) => null,
);
