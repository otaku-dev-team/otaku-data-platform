package com.otaku.work.dto;

import com.otaku.common.PageResponse;

import java.util.List;

/**
 * 作品列表的分页信封：比通用 {@link PageResponse} 多一个 {@code hidden}。
 *
 * <p><b>为什么不直接给 {@code PageResponse} 加字段</b>：那是资讯、收藏、评论、站主后台
 * 共用的信封。加一个字段，那些接口的 schema 就都被要求带上它——契约漂移测试当场报了 5 处
 * （ArticlePage 少字段、UgcCommentPage 等多字段）。而「被过滤掉了多少」只有作品列表有这个概念。
 *
 * <p>{@code hidden} 是**当前筛选条件下**因为成人遮挡被藏掉的条数，不是全库成人总数：
 * 用户改了类型 / 标签 / 年份 / 关键词，这个数字要跟着变，才对得上他眼前的列表。
 */
public record WorkPageResponse(
        int page,
        int pageSize,
        long total,
        int totalPages,
        List<WorkSummaryDto> items,
        long hidden
) {

    public static WorkPageResponse of(int page, int pageSize, long total,
                                      List<WorkSummaryDto> items, long hidden) {
        return new WorkPageResponse(page, pageSize, total,
                PageResponse.totalPages(total, pageSize), items, hidden);
    }
}
