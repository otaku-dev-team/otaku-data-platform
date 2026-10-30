import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_layout.dart';
import 'source_badge.dart';

/// 占位层的两种形态。
///
/// 同一套占位在小海报上好看、放到整屏头图上就难看：小尺寸的渐变 + 首字是
/// 「有内容但没配图」，放大到整屏就变成一块喧宾夺主的色块。
/// 所以按用途分两档，语义（没有封面 / 加载失败）完全一致，只是画法不同。
enum CoverPlaceholderStyle {
  /// 海报位（网格卡、列表磁贴、详情页小海报）：浅蓝灰渐变 + 首字水印。
  poster,

  /// 头图位（首页精选大图、详情页沉浸头图）：深色渐变 + 极淡高光，
  /// 不画字——它要当白字的背景，越安静越好。
  hero,
}

/// 统一的封面展示。
///
/// 契约 6.3：`cover_url` 为 `null` → 显示占位图，**不得空白、不得显示报错图**。
/// 图片地址一律来自平台代理，客户端不直连来源站。
///
/// 三种缺失状态要能区分开，否则 bangumi 那批「本来就没有封面」的条目
/// 会被误读成「图片加载失败」：
/// - 没有封面 → 浅蓝灰渐变 + 作品首字（尺寸够时改成图标 +「暂无封面」）
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
    this.placeholderStyle = CoverPlaceholderStyle.poster,
    this.source,
  });

  final String? url;
  final double width;
  final double height;
  final double radius;

  /// 无封面时显示的字（取作品标题首字），形状对齐来源站的占位层。
  /// 传 `null` 则退回图标占位——详情页那种大图更适合图标 + 文字说明。
  final String? placeholderLabel;

  /// 占位层的画法。头图位传 [CoverPlaceholderStyle.hero]。
  final CoverPlaceholderStyle placeholderStyle;

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
    CoverPlaceholderStyle style = CoverPlaceholderStyle.poster,
  }) => _CoverFallback(
    width: width,
    height: height,
    loading: false,
    label: label,
    style: style,
  );

  @override
  Widget build(BuildContext context) {
    // 按**实际显示尺寸**解码，而不是把来源图原尺寸全解出来：
    // 后端 `/api/covers` 实测单张 40KB–460KB，原图长边常在 1000px 以上，
    // 网格里一次十几张全尺寸解码会明显卡顿、也更容易被系统回收。
    // 拿不到有限宽度（网格/头图传的是 infinity）时用父级约束。
    return LayoutBuilder(
      builder: (context, constraints) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final targetWidth = width.isFinite && width > 0
            ? width
            : (constraints.maxWidth.isFinite
                  ? constraints.maxWidth
                  : MediaQuery.sizeOf(context).width);
        final cacheWidth = (targetWidth * dpr).round().clamp(48, 1600).toInt();

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
                  // 解码与磁盘缓存都按显示尺寸压一档：换来的是首屏更快、
                  // 滚动时不再反复解大图。
                  memCacheWidth: cacheWidth,
                  maxWidthDiskCache: cacheWidth,
                  placeholder: (context, url) => loadingFallback(
                    width: width,
                    height: height,
                  ),
                  errorWidget: (context, url, error) => errorFallback(
                    width: width,
                    height: height,
                    label: placeholderLabel,
                    style: placeholderStyle,
                  ),
                )
            : errorFallback(
                width: width,
                height: height,
                label: placeholderLabel,
                style: placeholderStyle,
              );

        if (badge == null) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: cover,
          );
        }

        return ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: _boxIfSized(
            Stack(
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
          ),
        );
      },
    );
  }

  /// 给徽章层补一个尺寸框：只有 **宽高都有限** 时才补。
  ///
  /// [Stack] 自己不带尺寸，它要靠 `Positioned.fill` 的子节点或父级约束才有界。
  /// 横向条（`CompactWorkCard`）和列表行（`WorkListTile`）是把 [CoverImage]
  /// 直接放进 `Column` / `Row` 的——这两条轴向上的交叉约束是**无界**的，
  /// Stack 拿不到有限尺寸就会抛 `A Stack requires bounded constraints`，
  /// 整张卡片渲染不出来（首页「高分作品」在真数据下曾整块空白，
  /// 因为只有真数据才带 `source`，假数据不走这一层）。
  ///
  /// 网格那条路（`WorkCard` / 收藏卡）传的是 `double.infinity`，父级还有一层
  /// [AspectRatio] 兜着，约束本来就有界；这里要是也套框，反而会在无界父级下
  /// 报 "BoxConstraints forces an infinite height"。所以按 {有限} 分流：
  /// 有限 → 自己给框；无限 → 交给父级。
  Widget _boxIfSized(Widget child) =>
      width.isFinite && height.isFinite
          ? SizedBox(width: width, height: height, child: child)
          : child;
}

class _CoverFallback extends StatelessWidget {
  const _CoverFallback({
    required this.width,
    required this.height,
    required this.loading,
    this.label,
    this.style = CoverPlaceholderStyle.poster,
  });

  final double width;
  final double height;

  /// 加载中只画骨架，不画图标，避免和「本来就没有封面」混淆。
  final bool loading;

  final String? label;

  final CoverPlaceholderStyle style;

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
      return switch (style) {
        CoverPlaceholderStyle.poster => _PosterPlaceholder(
          width: width,
          height: height,
          label: text,
        ),
        CoverPlaceholderStyle.hero => _HeroPlaceholder(
          width: width,
          height: height,
          label: text,
        ),
      };
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

/// 海报占位层：很淡的蓝灰渐变 + 标题首字。
///
/// 早先抄的是来源站 `.work-cover`（饱和蓝 + 135° 斜纹 + 大首字）。问题是
/// bangumi 那批条目**大多本来就没有封面**，「高分作品」一排三张全是斜纹时
/// 整块比正文还抢眼，看起来更像加载失败。现在压成接近纸面的浅蓝灰渐变，
/// 首字调到半透明做水印：一眼能看出「这张有内容、只是没配图」，又不会
/// 把视线从标题上拽走。加载态仍是纯灰块，两者依旧区分得开。
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
                colors: [Color(0xFFE9F2FB), Color(0xFFD5E5F4)],
              ),
            ),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: side * 0.3,
                  fontWeight: FontWeight.w700,
                  // 站点 --on-bright-soft 压低到 45%：水印而不是标题。
                  color: const Color(0x730A2D42),
                  height: 1,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 头图位占位：深色渐变 + 一层极淡高光，不画斜纹、不画首字。
///
/// 头图是白字的背景，占位必须「安静」：色相由首字决定（同一部作品每次进来
/// 颜色一致，不同作品之间又有区分），除此之外不加任何抢视线的元素。
class _HeroPlaceholder extends StatelessWidget {
  const _HeroPlaceholder({
    required this.width,
    required this.height,
    required this.label,
  });

  final double width;
  final double height;
  final String label;

  /// 全是深色系：头图上要压白字，浅底无论加多重的压暗层都读不清。
  static const _palettes = <List<Color>>[
    [Color(0xFF16324F), Color(0xFF2B5F7E)],
    [Color(0xFF2A2144), Color(0xFF4B3A72)],
    [Color(0xFF16352C), Color(0xFF2E6650)],
    [Color(0xFF3E2330), Color(0xFF6B3B4C)],
    [Color(0xFF2C2818), Color(0xFF584D2F)],
    [Color(0xFF17333A), Color(0xFF2F5B63)],
  ];

  /// 自己算一遍码位和，不用 `String.hashCode`：后者不保证跨进程稳定，
  /// 「同一部作品换次启动就换颜色」比没颜色更怪。
  List<Color> get _palette {
    var sum = 0;
    for (final unit in label.codeUnits) {
      sum = (sum * 31 + unit) & 0x3FFFFFFF;
    }
    return _palettes[sum % _palettes.length];
  }

  @override
  Widget build(BuildContext context) {
    final colors = _palette;

    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: colors,
          ),
        ),
        // 不再画首字水印：字号放到这个量级，笔画被边缘裁掉后只剩两根竖线，
        // 既认不出字又像渲染错位。改用一层极淡的径向高光，给平面一点体积。
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0.65, -0.75),
              radius: 1.2,
              colors: [
                Colors.white.withValues(alpha: 0.10),
                Colors.white.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
