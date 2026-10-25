import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_layout.dart';
import 'source_badge.dart';

/// 统一的封面展示。
///
/// 契约 6.3：`cover_url` 为 `null` → 显示占位图，**不得空白、不得显示报错图**。
/// 图片地址一律来自平台代理，客户端不直连来源站。
///
/// 三种缺失状态要能区分开，否则 bangumi 那批「本来就没有封面」的条目
/// 会被误读成「图片加载失败」：
/// - 没有封面 → 品牌色渐变 + 作品首字（尺寸够时改成图标 +「暂无封面」）
/// - 正在加载 → 纯骨架，无渐变无文字，避免和「本来就没有」混淆
/// - 加载失败 → 与「没有封面」同款，因为契约不允许出现破图
class CoverImage extends StatelessWidget {
  const CoverImage({
    super.key,
    required this.url,
    this.width = AppLayout.coverWidth,
    this.height = AppLayout.coverHeight,
    this.radius = 8,
    this.placeholderLabel,
    this.source,
  });

  final String? url;
  final double width;
  final double height;
  final double radius;

  /// 无封面时显示的字（取作品标题首字），形状对齐来源站的占位层。
  /// 传 `null` 则退回图标占位——详情页那种大图更适合图标 + 文字说明。
  final String? placeholderLabel;

  /// 来源站标识（W1.5 D3）。非空时在左下角贴一枚 [SourceBadge]：
  /// 只有跨源同名这条理由，够了才显示；`null` 表示来源没标注（含旧缓存）→ 不渲染。
  final String? source;

  /// 「正在加载」的占位：纯骨架，**无渐变、无文字**。
  ///
  /// 抽成公开方法是为了能直接测它——加载中这一态在 widget test 里
  /// 无法自然触发（见 [errorFallback] 的说明），但它恰恰是最容易被误改的一态：
  /// 一旦在这里画上渐变或首字，「正在加载」就会被误读成「本来就没有封面」。
  @visibleForTesting
  static Widget loadingFallback({
    required double width,
    required double height,
  }) =>
      _CoverFallback(width: width, height: height, loading: true);

  /// 「加载失败」与「本来就没有封面」的占位：**同一款**。
  ///
  /// 契约 6.3 不允许出现破图，所以加载失败不能显示报错图，只能回落到占位层。
  /// 「失败」与「本来就没有」在视觉上不分——这不是偷懒，而是契约的选择：
  /// 用户看到「一张带首字的占位图」，无论背后是没有封面还是图没下下来，
  /// 该做的动作（换一个封面、或者不管）是一样的。
  ///
  /// 为什么失败态在 widget test 里测不到：`cached_network_image` 走
  /// `flutter_cache_manager` 自己的 HTTP 栈，不受 flutter_test 的 400 拦截影响，
  /// 真实请求在 fake async 下不推进，错误回调永远不来（实测挂 12 秒仍停在
  /// 加载态）。所以把回调内容提成方法，直接测它渲染出什么。
  @visibleForTesting
  static Widget errorFallback({
    required double width,
    required double height,
    String? label,
  }) =>
      _CoverFallback(width: width, height: height, loading: false, label: label);

  @override
  Widget build(BuildContext context) {
    final imageUrl = url;
    final hasCover = imageUrl != null && imageUrl.isNotEmpty;
    final badge = source;

    final cover = hasCover
        ? CachedNetworkImage(
              imageUrl: imageUrl,
              width: width,
              height: height,
              fit: BoxFit.cover,
              fadeInDuration: const Duration(milliseconds: 160),
              placeholder: (context, url) => loadingFallback(
                width: width,
                height: height,
              ),
              errorWidget: (context, url, error) => errorFallback(
                width: width,
                height: height,
                label: placeholderLabel,
              ),
            )
          : errorFallback(
              width: width,
              height: height,
              label: placeholderLabel,
            );

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: badge == null
          ? cover
          : Stack(
              children: [
                Positioned.fill(child: cover),
                // 贴角而不是占一行：这里的高度（尤其是网格卡片）是按字号量死的，
                // 多一行会把正文挤出卡片。
                Positioned.directional(
                  textDirection: Directionality.of(context),
                  start: 6,
                  bottom: 6,
                  child: SourceBadge(source: badge),
                ),
              ],
            ),
    );
  }
}

class _CoverFallback extends StatelessWidget {
  const _CoverFallback({
    required this.width,
    required this.height,
    required this.loading,
    this.label,
  });

  final double width;
  final double height;

  /// 加载中只画骨架，不画图标，避免和「本来就没有封面」混淆。
  final bool loading;

  final String? label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (loading) {
      return Container(
        width: width,
        height: height,
        color: scheme.surfaceContainerHighest,
      );
    }

    final text = label;
    if (text != null && text.isNotEmpty) {
      return _PosterPlaceholder(width: width, height: height, label: text);
    }

    final compact = width < 96 || height < 96;
    return Container(
      width: width,
      height: height,
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.image_outlined,
            size: (width < height ? width : height) * 0.36,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
          // 列表卡片只有 64×88，塞不下文字，只在大尺寸（详情页）显示。
          if (!compact) ...[
            const SizedBox(height: 6),
            Text(
              '暂无封面',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 海报占位层：渐变底 + 斜纹 + 标题首字。
///
/// 抄的是来源站 `.work-cover`：纯色块在大面积上看着像"加载失败"，
/// 加一层 135° 斜纹和首字，观感上是"这张卡有内容但没配图"。
class _PosterPlaceholder extends StatelessWidget {
  const _PosterPlaceholder({
    required this.width,
    required this.height,
    required this.label,
  });

  final double width;
  final double height;
  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 网格里宽高由父级约束决定（传进来的是 infinity），字号按实际边长算。
          final side = constraints.biggest.shortestSide.isFinite
              ? constraints.biggest.shortestSide
              : 160.0;
          return DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFD6ECFF), Color(0xFF85CDFF), Color(0xFFAAECE6)],
                stops: [0, 0.58, 1],
              ),
            ),
            child: CustomPaint(
              painter: const _StripePainter(),
              child: Center(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: side * 0.24,
                    fontWeight: FontWeight.w800,
                    // 站点 --on-bright-soft：rgba(10, 45, 66, 0.72)
                    color: const Color(0xB80A2D42),
                    height: 1,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _StripePainter extends CustomPainter {
  const _StripePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..strokeWidth = 6;
    // 135° 斜纹，周期 20px，与站点 repeating-linear-gradient 一致。
    for (var x = -size.height; x < size.width + size.height; x += 26) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _StripePainter oldDelegate) => false;
}
