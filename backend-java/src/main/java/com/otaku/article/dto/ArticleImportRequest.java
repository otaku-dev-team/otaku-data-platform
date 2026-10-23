package com.otaku.article.dto;

import java.time.OffsetDateTime;
import java.util.List;

/**
 * 资讯导入请求体（内部接口 {@code POST /internal/import/articles}）。
 *
 * <p>形状与作品 / 档期的导入请求保持一致：同样的 batch_id 幂等键、同样的
 * source / fetched_at、同样的逐条结果语义。同步侧一套 importer 客户端
 * 能发三种批次，运维看 import_batch 表也是同一套口径。
 *
 * <p>与来源站 HTML 的对应关系（同步侧解析后填这里）：
 * <ul>
 *   <li>{@code title} ← {@code article-title} / {@code article-card-title}</li>
 *   <li>{@code summary} ← {@code article-card-summary}</li>
 *   <li>{@code body} ← {@code article-body} 的纯文本，一行一段</li>
 *   <li>{@code category} ← {@code article-meta} 的分类徽章</li>
 *   <li>{@code publishedAt} ← {@code article-byline} 的发布时间</li>
 *   <li>{@code sourceName} ← {@code article-source-origin}</li>
 *   <li>{@code sourceUrl} ← {@code article-source-link} 的 href（原文链接）</li>
 *   <li>{@code coverUrl} ← {@code article-card-thumb} 的 img，已拼成绝对地址</li>
 *   <li>{@code tags} ← {@code tag-chip} 指向 {@code /contents?tag=} 的标签名</li>
 * </ul>
 */
public record ArticleImportRequest(
        String batchId,
        String source,
        OffsetDateTime fetchedAt,
        List<ArticleImportItem> items
) {

    public record ArticleImportItem(
            String sourceId,
            String title,
            String summary,
            String body,
            String category,
            OffsetDateTime publishedAt,
            String sourceName,
            String sourceUrl,
            String coverUrl,
            List<String> tags,
            List<String> relatedWorkIds
    ) {
    }
}