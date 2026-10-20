import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_layout.dart';

/// 统一的封面展示。
///
/// 契约 6.3：`cover_url` 为 `null` → 显示占位图，**不得空白、不得显示报错图**。
/// 图片地址一律来自平台代理，客户端不直连来源站。
///
/// 三种缺失状态要能区分开，否则 bangumi 那批「本来就没有封面」的条目
/// 会被误读成「图片加载失败」：
/// - 没有封面 → 灰底 + 图标（尺寸够时带「暂无封面」）
/// - 正在加载 → 灰底、无图标无文字，纯骨架
/// - 加载失败 → 与「没有封面」同款，因为契约不允许出现破图
class CoverImage extends StatelessWidget {
  const CoverImage({
    super.key,
    required this.url,
    this.width = AppLayout.coverWidth,
    this.height = AppLayout.coverHeight,
    this.radius = 8,
  });

  final String? url;
  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final imageUrl = url;
    final hasCover = imageUrl != null && imageUrl.isNotEmpty;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: hasCover
          ? CachedNetworkImage(
              imageUrl: imageUrl,
              width: width,
              height: height,
              fit: BoxFit.cover,
              fadeInDuration: const Duration(milliseconds: 160),
              placeholder: (context, url) =>
                  _CoverFallback(width: width, height: height, loading: true),
              errorWidget: (context, url, error) =>
                  _CoverFallback(width: width, height: height, loading: false),
            )
          : _CoverFallback(width: width, height: height, loading: false),
    );
  }
}

class _CoverFallback extends StatelessWidget {
  const _CoverFallback({
    required this.width,
    required this.height,
    required this.loading,
  });

  final double width;
  final double height;

  /// 加载中只画骨架，不画图标，避免和「本来就没有封面」混淆。
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = width < 96 || height < 96;

    return Container(
      width: width,
      height: height,
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: loading
          ? null
          : Column(
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
