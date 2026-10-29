import 'dart:ui';

import 'package:flutter/material.dart';

/// 玻璃质感的底层背景。
///
/// 玻璃效果的关键是「透过去得有东西可看」——如果下面还是一片纯色，
/// 半透明只是把卡片调淡了。所以这里铺一层带柔和色块的渐变，
/// 由 [MaterialApp.builder] 垫在 Navigator 之下，所有页面共用同一张底图。
///
/// 色块用静态渐变、不做动画：滚动时重绘一层动画背景是在给每一帧加负担，
/// 而用户看的是它上面的内容。
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                scheme.surfaceContainerLowest,
                scheme.surface,
                scheme.surfaceContainerLow,
              ],
            ),
          ),
        ),
        // 两团柔和的色块：给上面的模糊层一点可模糊的内容。
        Positioned(
          top: -120,
          right: -60,
          child: _Blob(color: scheme.primary, size: 320),
        ),
        Positioned(
          bottom: -160,
          left: -80,
          child: _Blob(color: scheme.secondary, size: 380),
        ),
        child,
      ],
    );
  }
}

class _Blob extends StatelessWidget {
  const _Blob({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 90, sigmaY: 90),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.35),
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

/// 一段真正的「玻璃」：模糊它后面的内容，再叠一层极淡的填充和描边。
///
/// 模糊是 [BackdropFilter]，代价是要读一次背景像素——所以只用在**少量、
/// 常驻**的地方（底栏、侧栏、抽屉），不要包在每张卡片上：列表里几十个
/// BackdropFilter 会直接把滚动帧时间吃掉。
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.blur = 18,
    this.tintAlpha = 0.55,
    this.borderRadius = BorderRadius.zero,
  });

  final Widget child;

  /// 模糊半径。18 是「能看出是玻璃但还看得清下面」的量；
  /// 再大就变成一块没内容的雾面。
  final double blur;

  /// 叠在模糊之上的填充透明度。
  final double tintAlpha;

  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: tintAlpha),
            borderRadius: borderRadius,
            border: Border.all(
              color: scheme.outline.withValues(alpha: 0.14),
              width: 1,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
