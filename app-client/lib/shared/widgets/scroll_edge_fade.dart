import 'package:flutter/material.dart';

/// 给横向滚动区加右缘渐隐。
///
/// 窄屏上横滑列表必然把最后一枚胶囊切掉一半——不加这层，切边是一条直上直下
/// 的硬线，看着像渲染坏了；加了之后是「还能往右滑」的暗示。
///
/// 作品库筛选栏、资讯分类、档期星期三处共用同一份实现：它们宽度不同、
/// 条目不同，但都贴着页面背景（`colorScheme.surface`），渐隐色才能对上。
class ScrollEdgeFade extends StatelessWidget {
  const ScrollEdgeFade({super.key, required this.child, this.width = 28});

  /// 要包住的横向滚动内容。
  final Widget child;

  /// 渐隐带宽度。太窄盖不住胶囊的圆角边缘，还是会露出硬切。
  final double width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Stack(
      children: [
        child,
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          child: IgnorePointer(
            child: Container(
              width: width,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    scheme.surface.withValues(alpha: 0),
                    scheme.surface.withValues(alpha: 0.9),
                    scheme.surface,
                  ],
                  stops: const [0, 0.5, 1],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
