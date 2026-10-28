import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_layout.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/article.dart';
import 'article_meta_line.dart';

/// 资讯卡片：标题 + 摘要 + 分类/时间/来源 + 可选的原文链接入口。
///
/// **原文链接是「去来源站看」的入口，不是装饰**（项目章程 G3
/// 「用户不被困在平台内」）：有链接就显示，没有就整块不渲染——
/// 给一个指向空处的按钮比不给更糟。
///
/// 卡片整体可点进详情；原文链接是**独立的小链接**，与卡片点击互不打架
/// （在 Flutter 里点 InkWell 内的 TextButton 不会触发外层 InkWell）。
class ArticleCard extends StatelessWidget {
  const ArticleCard({super.key, required this.article, this.onTap});

  final ArticleSummary article;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cover = article.coverUrl;

    // 与作品卡同一套容器：卡片白底 + 0.5 描边 + 卡圆角 + 极轻阴影。
    // 阴影走 Material 的 elevation 而不是再包一层 Container：
    // 这里没有 hover 变换，不需要 PosterCardShell 那套。
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
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (cover != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(
                    AppLayout.innerRadius,
                  ),
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
                    loadingBuilder: (context, child, progress) =>
                        progress == null
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
        ),
      ),
    );
  }
}

/// 「在来源站查看」链接（章程 G3）。
///
/// **只用 http/https**：外链交给系统浏览器，恶意 scheme
/// （`javascript:`、`intent:`）不该由客户端代为发起。
class OriginalLinkButton extends StatelessWidget {
  const OriginalLinkButton({super.key, required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
          foregroundColor: scheme.primary,
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