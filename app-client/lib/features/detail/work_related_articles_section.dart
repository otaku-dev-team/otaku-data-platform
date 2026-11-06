import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/route_paths.dart';
import '../../core/theme/design_tokens.dart';
import '../../data/datasources/work_articles_data_source.dart';
import '../article/article_card.dart';

/// 作品详情页底部的「相关资讯」（#410，消费 #409 的
/// `GET /api/works/{work_id}/articles`）。
///
/// 三条边界与 [RelatedWorksSection] 一致，形状刻意做成同一套：
/// - **没有关联资讯** → 服务端返回 `200 + total:0 + items:[]`，此时**整块不渲染**。
///   不显示「暂无相关资讯」——切流前服务端开关关着，空是常态，写一句空态
///   反而会让人以为接口坏了（#410 评论里 pyxz0 明确要求）。
/// - **请求失败** → 同样整块不渲染。相关资讯是延伸阅读，不能因为拿不到它
///   就把作品本身的信息也拖进错误态。
/// - **作品不存在 / 成人 / 未收录** → 404 由详情页整体处理，这里跑不到。
///
/// 卡片用**竖列**而不是横滑：`ArticleCard` 是整行版式（标题 + 摘要 + 元信息），
/// 塞进固定高度的横滑列表会把摘要截没；与相关作品的横滑卡片不是一类东西。
///
/// 真数据在「数据侧把 `related_work_ids` 切到 subject id」之后才有；
/// 在那之前看到的是空区块，属预期（Mock 数据源为了看版式给了两条）。
class WorkRelatedArticlesSection extends ConsumerWidget {
  const WorkRelatedArticlesSection({super.key, required this.workId});

  final String workId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final value = ref.watch(workArticlesProvider(workId));

    // 加载中给一条占位，避免区块「先不显示、再突然顶出来」抖动。
    if (value.isLoading && !value.hasValue) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: Space.s3),
        child: SizedBox(
          height: 96,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    final page = value.value;
    if (value.hasError || page == null || page.items.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: Space.s4),
        Text('相关资讯', style: theme.textTheme.titleMedium),
        const SizedBox(height: Space.s3),
        for (final article in page.items) ...[
          ArticleCard(
            article: article,
            onTap: () => context.push(
              RoutePaths.articleDetail(article.articleId),
            ),
          ),
          const SizedBox(height: Space.s2),
        ],
        // 只取第一页。若有更多，如实说清「没显示全部」，不假装能翻页，
        // 也不做一个点了没反应的「查看更多」。
        if (page.hasNext)
          Padding(
            padding: const EdgeInsets.only(top: Space.s1),
            child: Text(
              '仅显示最近 ${page.items.length} 条（共 ${page.total} 条）',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
