import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_layout.dart';
import '../../data/models/work_summary.dart';

/// 提前把「接下来可能看到」的封面放进缓存。
///
/// 为什么需要：`CachedNetworkImage` 是**widget 建出来才开始下载**——列表滚到新位置时，
/// 那一屏的封面才刚开始从网络拉，用户看到的就是一块块占位灰。实测单张封面
/// 46–197KB（600×863 的那张就有 193KB），移动网络下要几百毫秒到一秒多。
///
/// 做法：在当前渲染的条目之后预取若干张。等用户滑到那里，文件已经在磁盘里，
/// `CachedNetworkImage` 直接命中缓存。
///
/// **命中靠的是 cacheKey 完全一致**：`CachedNetworkImage` 内部用
/// `CachedNetworkImageProvider(url, maxWidth: maxWidthDiskCache)` 取图，
/// 所以这里必须传同一个 `width`（调用点要跟实际卡片的宽度对齐），
/// 否则会往缓存里塞第二份、白白多下一次。
///
/// 刻意不做的两件事：
///
/// - **不预取整页**。一页 20 张 × 平均 144KB ≈ 2.9MB，等于是把用户还没看的东西
///   也下载了；默认只取紧接着的 4 张。
/// - **不 await、失败不冒泡**。预取是尽力而为，失败了下一次滚动还会再触发；
///   让它挡住列表构建或把异常抛到 UI 上没有意义。
void prefetchCovers(
  BuildContext context,
  Iterable<WorkSummary> works, {
  double? width,
  int count = 4,
}) {
  final dpr = MediaQuery.devicePixelRatioOf(context);
  final targetWidth = width ?? AppLayout.coverWidth;
  // 与 `CoverImage` 里的算法保持一致（同样 clamp 到 48..1600），否则 cacheKey 对不上。
  final cacheWidth = (targetWidth * dpr).round().clamp(48, 1600).toInt();

  var taken = 0;
  for (final work in works) {
    if (taken >= count) break;
    final url = work.coverUrl;
    if (url == null || url.isEmpty) continue;
    taken++;
    unawaited(
      precacheImage(
        CachedNetworkImageProvider(url, maxWidth: cacheWidth),
        context,
      ).catchError((Object _) {
        // 预取失败（网络抖动、页面已卸载）什么都不做：真正的加载还在后面。
      }),
    );
  }
}
