package com.otaku.importer.dto;

import com.otaku.work.dto.WorkCharacterDto;
import com.otaku.work.dto.WorkStaffDto;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;

/**
 * 接口②请求体。JSON 键名由 SNAKE_CASE 策略转换，与契约完全一致：
 * batch_id / source / fetched_at / items[source_id, work_type, title, summary,
 * cover_url, release_year, tags, main_rating, source_url, title_original, aliases,
 * media, episodes, staff, characters, studios]
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
            Integer releaseYear,
            List<String> tags,
            SourceRating mainRating,
            String sourceUrl,
            String titleOriginal,
            List<String> aliases,
            String media,
            Integer episodes,
            List<WorkStaffDto> staff,
            List<WorkCharacterDto> characters,
            List<String> studios
    ) {
    }

    public record SourceRating(BigDecimal value, String scale, String source) {
    }
}
