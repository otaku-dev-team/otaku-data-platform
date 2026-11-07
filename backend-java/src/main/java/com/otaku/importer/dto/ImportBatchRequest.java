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
 * media, episodes, staff, characters, studios, series_key, series_name]
 *
 * <p>{@code series_key} / {@code series_name}（#411）只有**数据集通道**会给：
 * 站点 REST 接口没有系列概念。省略或 null = 不覆盖库里已有的系列归属。
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
            List<String> studios,
            String seriesKey,
            String seriesName
    ) {

        /**
         * 不带系列字段的构造器：**站点 REST 通道**与既有测试用它。
         *
         * <p>站点接口没有系列概念，构造出来的条目两个字段都是 null = 「本次没有系列信息」，
         * 导入层据此不覆盖库里已有归属。保留这个重载是为了不让「加了一个只有数据集通道
         * 才有的字段」变成 29 处调用点的机械改动——那些调用点本来就不该关心系列。
         * Jackson 反序列化走的是规范构造器（18 参），不受这个重载影响。
         */
        public ImportItem(String sourceId, String workType, String title, String summary,
                          String coverUrl, Integer releaseYear, List<String> tags,
                          SourceRating mainRating, String sourceUrl, String titleOriginal,
                          List<String> aliases, String media, Integer episodes,
                          List<WorkStaffDto> staff, List<WorkCharacterDto> characters,
                          List<String> studios) {
            this(sourceId, workType, title, summary, coverUrl, releaseYear, tags, mainRating,
                    sourceUrl, titleOriginal, aliases, media, episodes, staff, characters,
                    studios, null, null);
        }
    }

    public record SourceRating(BigDecimal value, String scale, String source) {
    }
}
