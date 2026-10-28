package com.otaku.work.dto;

import java.time.Instant;
import java.util.List;

/**
 * 详情：契约 2.1 的全部 19 个字段
 * （含 summary、release_year、title_original、aliases、media、episodes、
 * source、source_id、source_url、updated_at，以及关联数组 staff / characters / studios）。
 * 列表接口是 7 字段（含 release_year），不含本类的
 * summary / title_original / aliases / media / episodes / source / source_id /
 * source_url / updated_at / staff / characters / studios。
 *
 * <p>staff / characters / studios 三者的数据接线归后端档 B 实现（#255）；
 * 此处字段先占位（{@code WorkService.detail} 目前传 {@code null}），契约侧均为 {@code nullable}。
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
        Instant updatedAt
) {
}
