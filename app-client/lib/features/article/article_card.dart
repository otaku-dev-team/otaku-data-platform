import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_layout.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/article.dart';
import '../../shared/widgets/cover_image.dart';
import 'article_meta_line.dart';

/// 资讯卡片：标题 + 摘要 + 分类/时间/来源 + 可选的原文链接入口。
///
/// [featured] 为 true 时走另一套版式：整块大图 + 底部压暗 + 白字，用来顶在
/// 列表第一条。资讯类 App 首页/频道页基本都是「一条头条 + 若干条列表」，
/// 全是同规格小卡时读者要靠逐条读标题才知道哪条重要。
///
/// **原文链接是「去来源站看」的入口，不是装饰**（项目章程 G3
/// 「用户不被困在平台内」）：有链接就显示，没有就整块不渲染——
/// 给一个指向空处的按钮比不给更糟。
///
/// 卡片整体可点进详情；原文链接是**独立的小链接**，与卡片点击互不打架
/// （在 Flutter 里点 InkWell 内的 TextButton 不会触发外层 InkWell）。
class ArticleCard extends StatelessWidget {
  const ArticleCard({
    super.key,
    required this.article,
    this.onTap,
    this.featured = false,
  });

  final ArticleSummary article;
  final VoidCallback? onTap;

  /// 头条版式。仍然是一个 [ArticleCard]——页面按条渲染的语义不变，
  /// 变的只是这一条的画法。
  final bool featured;

  /// 头条高度：够放两行标题 + 元信息，又不至于占掉半屏。
  static const double _featuredHeight = 204;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.cardColor(context),
      elevation: 1,
      shadowColor: const Color(0x2E143652),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        side: BorderSide(color: AppTheme.borderColor(context), width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        child: featured ? _buildFeatured(context) : _buildRow(context),
      ),
    );
  }

  /// 头条：大图铺满 + 底部压暗 + 白字。无封面时用 [CoverPlaceholderStyle.hero]
  /// 的深色渐变兜底，和首页精选大图是同一套观感。
  Widget _buildFeatured(BuildContext context) {
    final theme = Theme.of(context);
    final firstChar = article.title.characters.isEmpty
        ? null
        : article.title.characters.first;
    final meta = [
      if (article.category case final String value when value.isNotEmpty) value,
      ?formatArticleDate(article.publishedAt),
      if (article.sourceName case final String value when value.isNotEmpty)
        value,
    ].join(' · ');

    return SizedBox(
      height: _featuredHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CoverImage(
            url: article.coverUrl,
            width: double.infinity,
            height: double.infinity,
            radius: 0,
            placeholderLabel: firstChar,
            placeholderStyle: CoverPlaceholderStyle.hero,
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x000B1620), Color(0xE60B1620)],
                stops: [0.3, 1],
              ),
            ),
          ),
          Positioned(
            left: 14,
            right: 14,
            bottom: 12,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '头条',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.75),
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  article.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.82),
                    ),
                  ),
                ],
                if (article.sourceUrl != null)
                  OriginalLinkButton(url: article.sourceUrl!, onDark: true),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cover = article.coverUrl;

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (cover != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(AppLayout.innerRadius),
              child: Image.network(
                cover,
                width: 96,
                height: 64,
                fit: BoxFit.cover,
                // 资讯首图是来源站的静态文件，加载失败不该让整张卡片崩掉。
                // 显示占位块而不是图标：图片本来就不是这条资讯的主体。
                errorBuilder: (context, error, stack) => Container(
                  width: 96,
                  height: 64,
                  color: scheme.surfaceContainerHighest,
                ),
                loadingBuilder: (context, child, progress) => progress == null
                    ? child
                    : Container(
                        width: 96,
                        height: 64,
                        color: scheme.surfaceContainerHighest,
                      ),
              ),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  article.title,
                  style: theme.textTheme.titleSmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (article.summary != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    article.summary!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 6),
                ArticleMetaLine(
                  category: article.category,
                  publishedAt: article.publishedAt,
                  sourceName: article.sourceName,
                ),
                if (article.sourceUrl != null) ...[
                  const SizedBox(height: 4),
                  OriginalLinkButton(url: article.sourceUrl!),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 「在来源站查看」链接（章程 G3）。
///
/// **只用 http/https**：外链交给系统浏览器，恶意 scheme
/// （`javascript:`、`intent:`）不该由客户端代为发起。
class OriginalLinkButton extends StatelessWidget {
  const OriginalLinkButton({super.key, required this.url, this.onDark = false});

  final String url;

  /// 压在头图暗底上时用白字：主色蓝在深绿/深蓝渐变上对比度不够。
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final lower = url.toLowerCase();
    final safe = lower.startsWith('http://') || lower.startsWith('https://');
    if (!safe) return const SizedBox.shrink();

    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => launchExternalUrl(context, url),
        icon: const Icon(Icons.open_in_new, size: 14),
        label: Text('在来源站查看'),
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: const Size(0, 28),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: onDark ? Colors.white : AppTheme.brandInk(context),
          textStyle: Theme.of(context).textTheme.labelSmall,
        ),
      ),
    );
  }
}

/// 外链跳转的唯一入口。
///
/// 包一层是为了让测试能替换，也为了在这里集中做 scheme 校验——
/// 散落在各处 `launchUrl` 迟早会漏一处。
Future<void> launchExternalUrl(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  final lower = uri.scheme.toLowerCase();
  if (lower != 'http' && lower != 'https') return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final launched = await launchUrl(uri);
    // 返回 false 通常是没有可处理该链接的 App（如没装浏览器）。
    // 静默失败会让用户以为已经跳转了，所以明确说一声。
    if (!launched && messenger != null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('没有可打开链接的应用')),
      );
    }
  } on Object {
    messenger?.showSnackBar(
      const SnackBar(content: Text('打开来源站失败')),
    );
  }
}