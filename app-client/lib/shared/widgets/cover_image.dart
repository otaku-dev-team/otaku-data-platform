import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_layout.dart';

/// 统一的封面展示。
///
/// 契约 6.3：`cover_url` 为 `null` → 显示占位图，**不得空白、不得显示报错图**。
/// 图片地址一律来自平台代理，客户端不直连来源站。
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
    final placeholder = _Placeholder(width: width, height: height);
    final imageUrl = url;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: imageUrl == null || imageUrl.isEmpty
          ? placeholder
          : CachedNetworkImage(
              imageUrl: imageUrl,
              width: width,
              height: height,
              fit: BoxFit.cover,
              fadeInDuration: const Duration(milliseconds: 160),
              placeholder: (context, url) => placeholder,
              errorWidget: (context, url, error) => placeholder,
            ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: height,
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        Icons.image_outlined,
        size: (width < height ? width : height) * 0.36,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
      ),
    );
  }
}
