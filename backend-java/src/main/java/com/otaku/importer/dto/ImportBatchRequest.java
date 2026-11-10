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
 * media, episodes, staff, characters, studios, series_key, series_name,
 * official_url, broadcast_start, broadcast_end, planning]
 *
 * <p>{@code series_key} / {@code series_name}（#411）只有**数据集通道**会给：
 * 站点 REST 接口没有系列概念。省略或 null = 不覆盖库里已有的系列归属。
 *
 * <p>{@code official_url} / {@code broadcast_start} / {@code broadcast_end} / {@code planning}
 *（#564 信息卡）同理：只有**数据集通道**会给，站点 REST 通道没有这些信息；
 * 四者各自独立、省略或 null = 本次没拿到该字段，**不覆盖**库里已有值（不置空）。
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
            String seriesName,
            String officialUrl,
            String broadcastStart,
            String broadcastEnd,
            String planning
    ) {

        /**
         * 不带系列字段的构造器：**站点 REST 通道**与既有测试用它。
         *
         * <p>站点接口没有系列概念，构造出来的条目两个字段都是 null = 「本次没有系列信息」，
         * 导入层据此不覆盖库里已有归属。保留这个重载是为了不让「加了一个只有数据集通道
         * 才有的字段」变成 29 处调用点的机械改动——那些调用点本来就不该关心系列。
         * Jackson 反序列化走的是规范构造器（22 参），不受这个重载影响。
         */
        public ImportItem(String sourceId, String workType, String title, String summary,
                          String coverUrl, Integer releaseYear, List<String> tags,
                          SourceRating mainRating, String sourceUrl, String titleOriginal,
                          List<String> aliases, String media, Integer episodes,
                          List<WorkStaffDto> staff, List<WorkCharacterDto> characters,
                          List<String> studios) {
            this(sourceId, workType, title, summary, coverUrl, releaseYear, tags, mainRating,
                    sourceUrl, titleOriginal, aliases, media, episodes, staff, characters,
                    studios, null, null, null, null, null, null);
        }

        /**
         * 带系列、不带信息卡四字段的构造器：系列/搜索相关的集成测试用它。
         *
         * <p>V39 加列后规范构造器变 22 参，这些测试只关心系列归属，不该被迫补四个
         * 与它们无关的 null。信息卡四字段一律 null = 本次不提供，导入层不覆盖库里已有值。
         */
        public ImportItem(String sourceId, String workType, String title, String summary,
                          String coverUrl, Integer releaseYear, List<String> tags,
                          SourceRating mainRating, String sourceUrl, String titleOriginal,
                          List<String> aliases, String media, Integer episodes,
                          List<WorkStaffDto> staff, List<WorkCharacterDto> characters,
                          List<String> studios, String seriesKey, String seriesName) {
            this(sourceId, workType, title, summary, coverUrl, releaseYear, tags, mainRating,
                    sourceUrl, titleOriginal, aliases, media, episodes, staff, characters,
                    studios, seriesKey, seriesName, null, null, null, null);
        }
    }

    public record SourceRating(BigDecimal value, String scale, String source) {
    }
}
