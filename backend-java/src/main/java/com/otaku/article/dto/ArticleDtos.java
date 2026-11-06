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
     * 相关资讯（#414）。
     *
     * <p>为什么不是 {@code ArticlePage}：这是固定条数的「延伸阅读」，不是分页列表——
     * 给 `total` / `total_pages` 会让客户端以为还能翻页。`items` 为空表示没有相关资讯
     * （照样 200，与「这个分类没数据」同口径）。
     */
    public record ArticleRelated(
            List<ArticleSummary> items
    ) {
    }

    /**
     * 详情。比列表多 {@code body}（正文纯文本，一行一段）、
     * {@code relatedWorkIds}（来源站关联作品 id）与 {@code relatedWorks}（解析到本地作品后的列表）。
     *
     * <p>{@code relatedWorkIds} 里的值 2026-11-05 起是 <b>bangumi subject id</b>
     * （数据侧导出时 JOIN 好，见 #422）；切流前的存量行仍是站点 content_id。
     * 两者都是纯数字、从值上分不出来，所以客户端**一律不得**拿它自己匹配本地作品，
     * 卡片所需的一切字段都在 {@code relatedWorks} 里。
     *
     * <p>{@code relatedWorks} 由服务端解析：{@code null} = 语义开关还没切（不解析），
     * {@code []} = 已切但没有可用的本地作品。两者客户端都整块不渲染。
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

        /**
         * 填上解析后的关联作品（#408）。
         *
         * <p>解析要查 work 表、还要按收录范围与成人口径过滤，那套逻辑只在作品侧有一份
         * （{@code WorkService.summariesBySubjectIds}）。资讯这边不复制一份口径——
         * 复制出来的第二份早晚和第一份漂移，而漂移的表现是「详情页漏了某类作品」，不报错。
         */
        public ArticleDetail withRelatedWorks(List<WorkSummaryDto> resolved) {
            return new ArticleDetail(articleId, title, summary, body, category, publishedAt,
                    sourceName, sourceUrl, coverUrl, tags, relatedWorkIds, resolved);
        }
    }

    /** 分类筛选项，附该分类的条数。 */
    public record Category(String name, long count) {
    }
}