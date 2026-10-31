import 'package:flutter/material.dart';

import '../../core/theme/app_layout.dart';
import '../../core/theme/library_density.dart';

/// 首屏加载用骨架屏，而不是盖一层转圈遮罩——遮罩会让人误以为页面卡死。
class SkeletonList extends StatefulWidget {
  const SkeletonList({super.key, this.itemCount = 6});

  final int itemCount;

  @override
  State<SkeletonList> createState() => _SkeletonListState();
}

class _SkeletonListState extends State<SkeletonList>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 读屏用户看不到「灰色方块在呼吸」，只该听到一句「加载中」。
    // 不加这一层时这一幕是完全静默的，容易被当成页面没反应。
    return Semantics(
      container: true,
      label: '加载中',
      child: ExcludeSemantics(
        child: ListView.separated(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppLayout.pagePadding),
          itemCount: widget.itemCount,
          separatorBuilder: (context, index) => const SizedBox(height: 12),
          itemBuilder: (context, index) => _Pulse(
            animation: _controller,
            child: const _SkeletonRow(),
          ),
        ),
      ),
    );
  }
}

/// 首屏加载用骨架屏，网格版：与 [WorkCard] 同尺寸，避免加载完成后跳一下。
///
/// 密度与列数必须由调用方按当前设置传进来——骨架屏自己不知道用户在设置里
/// 选了哪一档，按默认档画就会出现「加载时 2 列宽卡、加载完变 3 列窄卡」的跳动。
class SkeletonGrid extends StatefulWidget {
  const SkeletonGrid({
    super.key,
    this.itemCount = 10,
    this.density = LibraryDensity.comfort,
    this.columns,
  });

  final int itemCount;

  /// 与真实网格同一档密度：决定列数、卡片高度、封面下方占位条的条数。
  final LibraryDensity density;

  /// 用户覆盖的列数；`null` = 按宽度自适应。与真实网格同源，不要在这里另算。
  final int? columns;

  @override
  State<SkeletonGrid> createState() => _SkeletonGridState();
}

class _SkeletonGridState extends State<SkeletonGrid>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final usable =
            constraints.maxWidth - AppLayout.pagePadding * 2;
        // 与真实网格同一套算法（contents_page 传进来的密度 + 列数覆盖）。
        final metrics = AppLayout.gridMetrics(
          usable,
          density: widget.density,
          overrideColumns: widget.columns,
        );
        // 与真实卡片（contents_page / work_card）同一套字号缩放，否则大字体下
        // 骨架行高和加载完的卡片行高对不上，首屏会出现一次明显的跳动。
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        // 高度也走同一个函数：以后调 2:3 或文字区高度，只改一处。
        final extent = AppLayout.gridCellExtent(
          cardWidth: metrics.cardWidth,
          density: widget.density,
          textScale: textScale,
        );

        return GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            AppLayout.pagePadding,
            8,
            AppLayout.pagePadding,
            AppLayout.pagePadding,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: metrics.columns,
            mainAxisExtent: extent,
            crossAxisSpacing: AppLayout.gridGap,
            mainAxisSpacing: AppLayout.gridGap,
          ),
          itemCount: widget.itemCount,
          itemBuilder: (context, index) => _Pulse(
            animation: _controller,
            child: _SkeletonPoster(density: widget.density),
          ),
        );
      },
    );
  }
}

class _SkeletonPoster extends StatelessWidget {
  const _SkeletonPoster({required this.density});

  final LibraryDensity density;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 封面位占满卡片剩余高度，与真实卡片的 2:3 版面一致。
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppLayout.cardRadius),
            ),
          ),
        ),
        // 占位条条数与真实卡片一致：舒适两条（两行标题 + 元信息），
        // 紧凑一条（一行标题），仅封面一条都不画——否则空态比结果还高。
        if (density != LibraryDensity.coversOnly) ...[
          const SizedBox(height: 10),
          const _Bar(width: double.infinity, height: 12),
          if (density == LibraryDensity.comfort) ...[
            const SizedBox(height: 8),
            const _Bar(width: 90, height: 12),
          ],
        ],
      ],
    );
  }
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Bar(
          width: AppLayout.coverWidth,
          height: AppLayout.coverHeight,
          radius: AppLayout.innerRadius,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 4),
              const _Bar(width: double.infinity, height: 16),
              const SizedBox(height: 10),
              const _Bar(width: 180, height: 12),
              const SizedBox(height: 10),
              const _Bar(width: 120, height: 12),
            ],
          ),
        ),
      ],
    );
  }
}

/// 详情页骨架：封面 + 标题 + 正文若干行。
class SkeletonDetail extends StatelessWidget {
  const SkeletonDetail({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppLayout.pagePadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Bar(width: double.infinity, height: 180, radius: 12),
          const SizedBox(height: 20),
          const _Bar(width: 240, height: 24),
          const SizedBox(height: 12),
          const _Bar(width: 160, height: 14),
          const SizedBox(height: 24),
          for (var i = 0; i < 5; i++) ...[
            const _Bar(width: double.infinity, height: 12),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _Pulse extends StatelessWidget {
  const _Pulse({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) => Opacity(
        opacity: 0.35 + 0.45 * animation.value,
        child: child,
      ),
      child: child,
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.width,
    required this.height,
    this.radius = 6,
  });

  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}
