package com.otaku.work.dto;

import java.time.Instant;
import java.util.List;

/**
 * 详情：契约 2.1 的全部 20 个字段
 * （含 summary、release_year、title_original、aliases、media、episodes、
 * source、source_id、source_url、updated_at，以及关联数组 staff / characters / studios）。
 * 列表接口是 7 字段（含 release_year），不含本类的
 * summary / title_original / aliases / media / episodes / source / source_id /
 * source_url / updated_at / staff / characters / studios / deleted。
 *
 * <p>staff / characters / studios 三者的数据接线归后端档 B 实现（#255）；
 * 此处字段先占位（{@code WorkService.detail} 目前传 {@code null}），契约侧均为 {@code nullable}。
 *
 * <p>{@code deleted} 是软删标记（#249）：已下架的作品**不再返回 404**，而是
 * {@code 200 + deleted:true}，客户端据此显示「已下架」占位——否则收藏里的条目会变成死链，
 * 用户会以为自己收藏丢了。列表/搜索/标签/年份四个面则完全不返回已删行。
 */
public record WorkDto(
        String workId,
        String workType,
        String title,
        String summary,
        Integer releaseYear,
        String titleOriginal,
        List<String> aliases,
        String media,
        Integer episodes,
        String coverUrl,
        List<String> tags,
        SourceRatingDto mainRating,
        List<WorkStaffDto> staff,
        List<WorkCharacterDto> characters,
        List<String> studios,
        String source,
        String sourceId,
        String sourceUrl,
        Instant updatedAt,
        boolean deleted
) {
}
