package com.otaku.importer.dto;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;

/**
 * 接口②请求体。JSON 键名由 SNAKE_CASE 策略转换，与契约完全一致：
 * batch_id / source / fetched_at / items[source_id, work_type, title, summary, cover_url, tags, main_rating]
 */
public record ImportBatchRequest(
        String batchId,
        String source,
        OffsetDateTime fetchedAt,
        List<ImportItem> items
) {

    public record ImportItem(
            String sourceId,
            String workType,
            String title,
            String summary,
            String coverUrl,
            List<String> tags,
            SourceRating mainRating
    ) {
    }

    public record SourceRating(BigDecimal value, String scale, String source) {
    }
}
