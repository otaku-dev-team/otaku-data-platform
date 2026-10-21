package com.otaku.work.dto;

import java.time.Instant;
import java.util.List;

/**
 * 详情：契约 2.1 的全部 12 个字段
 * （含 summary、release_year、source、source_id、source_url、updated_at）。
 * 列表接口是 7 字段（含 release_year），不含本类的
 * summary / source / source_id / source_url / updated_at。
 */
public record WorkDto(
        String workId,
        String workType,
        String title,
        String summary,
        Integer releaseYear,
        String coverUrl,
        List<String> tags,
        SourceRatingDto mainRating,
        String source,
        String sourceId,
        String sourceUrl,
        Instant updatedAt
) {
}
