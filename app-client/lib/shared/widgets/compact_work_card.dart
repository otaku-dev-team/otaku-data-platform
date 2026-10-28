import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';
import '../../data/models/work_summary.dart';
import 'cover_image.dart';
import 'rating_badge.dart';

/// 横向滚动条里用的紧凑作品卡：竖版海报 + 两行标题 + 评分。
///
/// 为什么不直接用列表页的 [WorkCard]：那张卡的正文字块有固定高度
/// （`AppLayout.cardBodyHeight`，按真实字体量出来的），只在网格里成立。
/// 放进高度固定的横向条时，只要字体度量稍有不同（测试环境、大字号）
/// 就会在卡片内部溢出。这里的布局是自适应高度的，外层给多少就用多少。
///
/// 详情页「同题材推荐」与首页「高分作品」共用这一张，
/// 否则两个横向条会做出两种细微不同的卡片。
class CompactWorkCard extends StatelessWidget {
  const CompactWorkCard({super.key, required this.work, required this.width});

  final WorkSummary work;
  final double width;

  /// 海报高度。宽高比与站点 `.work-cover-box` 一致（2:3）。
  static double coverHeightFor(double width) => width / AppLayout.posterAspect;

  /// 卡片总高度：海报 + 间距 + 两行标题 + 间距 + 评分行。
  ///
  /// 外层横向列表必须给一个确定高度（`ListView` 的横向滚动需要它），
  /// 而标题行高跟着系统字号缩放，所以这里一起接受 `textScale`。
  /// 额外留 8px：字体度量在不同平台略有差异，卡着算会偶发溢出。
  static double heightFor(double width, double textScale) =>
      coverHeightFor(width) + 76 * textScale + 8;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 无封面时用标题首字占位；`characters` 取整字，emoji 不会被截半个。
    final firstChar = work.title.characters.isEmpty
        ? null
        : work.title.characters.first;

    final titleStyle = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w600,
      height: 1.35,
    );
    // 标题固定占两行的高度：横排里有的标题一行、有的两行，不固定的话
    // 评分行会一张高一张低，整条带子底部参差（首页「最近浏览」实测最明显）。
    final scaler = MediaQuery.textScalerOf(context);
    final titleLineHeight = scaler.scale(
      (titleStyle?.fontSize ?? 14) * (titleStyle?.height ?? 1.35),
    );

    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppLayout.cardRadius),
        onTap: () => context.push(RoutePaths.workDetail(work.workId)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CoverImage(
              url: work.coverUrl,
              width: width,
              height: coverHeightFor(width),
              radius: AppLayout.cardRadius,
              placeholderLabel: firstChar,
              source: work.source,
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: titleLineHeight * 2,
              child: Text(
                work.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
            ),
            const SizedBox(height: 4),
            // 契约 6.3：没有评分整块不渲染，不显示 0.0。
            if (work.mainRating != null)
              RatingBadge(rating: work.mainRating, compact: true),
          ],
        ),
      ),
    );
  }
}
