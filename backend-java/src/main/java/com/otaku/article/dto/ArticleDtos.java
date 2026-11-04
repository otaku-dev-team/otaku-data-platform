package com.otaku.article.dto;

import com.otaku.work.dto.WorkSummaryDto;

import java.util.List;

/**
 * 公开接口的响应形状。
 *
 * <p>列表项与详情刻意分开：列表不带 {@code body}（正文可能几百 KB，
 * 一页 20 条就是几 MB，客户端列表页根本用不上），也不带
 * {@code related_work_ids}（客户端第一版不用，见 V9 迁移文件头）。
 * 详情才给全文与关联作品信息。
 */
public final class ArticleDtos {

    private ArticleDtos() {
    }

    /**
     * 一页资讯。
     *
     * <p>字段与 {@code PageResponse} 对齐（契约里 ArticlePage 是 allOf 了 Paging 的）。
     * 早期实现漏了 {@code total_pages}，客户端照契约读会拿到空——契约守卫抓到的。
     *
     * @param total      过滤后的总条数
     * @param page       当前页，从 1 起
     * @param pageSize   每页条数
     * @param totalPages 总页数，由 {@link com.otaku.common.PageResponse#totalPages} 统一计算
     * @param items      当前页条目，按发布时间倒序
     */
    public record ArticlePage(
            long total,
            int page,
            int pageSize,
            int totalPages,
            List<ArticleSummary> items
    ) {
    }

    /**
     * 列表项。
     *
     * @param sourceUrl 原文链接。客户端据此显示「在来源站查看」——
     *                为 null 时不给这个入口（章程 G3：想读原文的人不该被困在这里）。
     */
    public record ArticleSummary(
            String articleId,
            String title,
            String summary,
            String category,
            String publishedAt,
            String sourceName,
            String sourceUrl,
            String coverUrl,
            List<String> tags
    ) {
    }

    /**
     * 详情。比列表多 {@code body}（正文纯文本，一行一段）、
     * {@code relatedWorkIds}（来源站关联作品 id 原文）与
     * {@code relatedWorks}（解析到本地作品后的列表）。
     *
     * <p>{@code relatedWorkIds} 是 <b>站点 content_id</b>，与本地 {@code work_id}
     * 及 bangumi subject id 是三套号，客户端不得拿它拼本地详情路由（见 V9 迁移文件头、
     * 契约 ArticleDetail）。卡片所需的一切字段都在 {@code relatedWorks} 里。
     *
     * <p>{@code relatedWorks} 的解析（content_id → 首站 contents.bangumi_id →
     * 本地 work）归 #409；#409 落地前这里恒为 {@code null}，客户端整块不渲染。
     * 不在这里按数值猜 subject id：V28 实测会撞出 3,015 条假匹配。
     */
    public record ArticleDetail(
            String articleId,
            String title,
            String summary,
            String body,
            String category,
            String publishedAt,
            String sourceName,
            String sourceUrl,
            String coverUrl,
            List<String> tags,
            List<String> relatedWorkIds,
            List<WorkSummaryDto> relatedWorks
    ) {
    }

    /** 分类筛选项，附该分类的条数。 */
    public record Category(String name, long count) {
    }
}