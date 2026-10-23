import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/router/route_paths.dart';
import '../../core/theme/app_layout.dart';
import '../../data/models/article.dart';
import '../../shared/widgets/error_state.dart';
import '../../shared/widgets/tag_chips.dart';
import 'article_card.dart';
import 'article_controller.dart';
import 'article_meta_line.dart';

/// 资讯详情。
///
/// 与作品详情同一套状态矩阵（契约 6.2 / 6.3）：
/// - 加载中 → 骨架；
/// - 404 → 「资讯不存在」+ 返回列表，**不自动重试**；
/// - 其他错误 → 提示 + 重试。
///
/// 正文可能整段缺失（来源页抓不到正文时 sync 不会丢这条资讯，只是没有 body）。
/// 那种情况下**照样展示标题与摘要**，并保留原文入口：章程 G3 要求用户
/// 不被困在平台内，正文抓不到时「去来源站看」反而更重要。
class ArticleDetailPage extends ConsumerWidget {
  const ArticleDetailPage({super.key, required this.articleId});

  final String articleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(articleDetailProvider(articleId));
    final sourceUrl = detail.value?.sourceUrl;

    return Scaffold(
      appBar: AppBar(
        title: const Text('资讯详情'),
        actions: [
          if (sourceUrl != null)
            IconButton(
              tooltip: '在来源站查看',
              onPressed: () => launchExternalUrl(context, sourceUrl),
              icon: const Icon(Icons.open_in_new_rounded),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppLayout.detailMaxWidth),
          child: _buildBody(context, ref, detail),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<ArticleDetail> detail,
  ) {
    // Riverpod 3 里「失败后正在重试」是 `AsyncLoading(error: …)`，
    // 只判 isLoading 会让错误态永远停在骨架屏上（这里已经关掉自动重试，
    // 但保险起见把 hasError 一起判掉）。
    if (detail.isLoading && !detail.hasValue && !detail.hasError) {
      return const _ArticleDetailSkeleton();
    }

    if (detail.hasError) {
      final error = ApiException.fromAny(detail.error);
      if (error.isNotFound) {
        return ErrorState(
          error: error,
          title: '资讯不存在',
          action: OutlinedButton(
            onPressed: () => _backToList(context),
            child: const Text('返回列表'),
          ),
        );
      }
      return ErrorState(
        error: error,
        onRetry: () => ref.invalidate(articleDetailProvider(articleId)),
      );
    }

    return _ArticleDetailBody(article: detail.requireValue);
  }

  void _backToList(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(RoutePaths.articles);
    }
  }
}

class _ArticleDetailBody extends StatelessWidget {
  const _ArticleDetailBody({required this.article});

  final ArticleDetail article;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final paragraphs = article.paragraphs;
    final cover = article.coverUrl;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppLayout.pagePadding,
        12,
        AppLayout.pagePadding,
        32,
      ),
      children: [
        if (cover != null) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(
              cover,
              width: double.infinity,
              height: 200,
              fit: BoxFit.cover,
              // 首图挂了不该让整页变空白：资讯的主体是文字。
              errorBuilder: (context, error, stack) => const SizedBox.shrink(),
            ),
          ),
          const SizedBox(height: 16),
        ],
        Text(article.title, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        ArticleMetaLine(
          category: article.category,
          publishedAt: article.publishedAt,
          sourceName: article.sourceName,
        ),
        if (article.sourceUrl != null) ...[
          const SizedBox(height: 4),
          OriginalLinkButton(url: article.sourceUrl!),
        ],
        const SizedBox(height: 12),
        if (article.tags != null) ...[
          TagChips(tags: article.tags, maxVisible: 8),
          const SizedBox(height: 12),
        ],
        if (article.summary != null) ...[
          Text(
            article.summary!,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (paragraphs.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              article.sourceUrl == null
                  ? '这条资讯没有正文'
                  : '这条资讯没有正文，可以去来源站看原文',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          )
        else
          for (final paragraph in paragraphs) ...[
            Text(
              paragraph,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.7),
            ),
            const SizedBox(height: 12),
          ],
      ],
    );
  }
}

/// 详情骨架。标题两行 + 元信息一行 + 若干正文行，
/// 形状对齐 [_ArticleDetailBody]，加载完成时不会有明显跳动。
class _ArticleDetailSkeleton extends StatelessWidget {
  const _ArticleDetailSkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = scheme.surfaceContainerHighest;

    Widget block(double width, double height) => Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: base,
            borderRadius: BorderRadius.circular(6),
          ),
        );

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppLayout.pagePadding,
        12,
        AppLayout.pagePadding,
        32,
      ),
      children: [
        Container(
          height: 200,
          decoration: BoxDecoration(
            color: base,
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        const SizedBox(height: 16),
        block(double.infinity, 22),
        const SizedBox(height: 10),
        block(180, 14),
        const SizedBox(height: 20),
        for (var i = 0; i < 8; i++) ...[
          block(double.infinity, 14),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}
