package com.otaku.work.dto;

import java.time.Instant;
import java.util.List;

/** 详情：契约 2.1 的全部 10 个字段（含 summary、source、source_id、updated_at）。 */
public record WorkDto(
        String workId,
        String workType,
        String title,
        String summary,
        String coverUrl,
        List<String> tags,
        SourceRatingDto mainRating,
        String source,
        String sourceId,
        Instant updatedAt
) {
}
