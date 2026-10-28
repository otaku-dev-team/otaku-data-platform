package com.otaku.importer;

import com.otaku.work.WorkRecord;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDateTime;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 钉住契约 5.5 的创建/更新规则——这段逻辑一旦写错，
 * 验收 D2（重跑不新增）、D3（改评分要更新）、D4（summary 不被清空）都会挂。
 */
class WorkMergerTest {

    private static final LocalDateTime T = LocalDateTime.of(2026, 10, 20, 6, 0);

    private static WorkRecord work(String summary, String tagsJson, String ratingValue) {
        return work(summary, tagsJson, ratingValue, null);
    }

    private static WorkRecord work(String summary, String tagsJson, String ratingValue,
                                   Integer releaseYear) {
        BigDecimal rating = ratingValue == null ? null : new BigDecimal(ratingValue);
        return new WorkRecord(1L, "W-test", "anime", "原标题", summary, releaseYear,
                null, null, null, null,
                "http://154.8.194.198:8000/media/full/cover_1.jpg", "cache-key", T,
                tagsJson, rating,
                rating == null ? null : "0-10",
                rating == null ? null : "otaku_site",
                "otaku_site", "476", null, T, T);
    }

    private static NormalizedItem item(String title, String summary, String tagsJson,
                                       String ratingValue, String coverUrl) {
        return item(title, summary, tagsJson, ratingValue, coverUrl, null);
    }

    private static NormalizedItem item(String title, String summary, String tagsJson,
                                       String ratingValue, String coverUrl, Integer releaseYear) {
        BigDecimal rating = ratingValue == null ? null : new BigDecimal(ratingValue);
        return new NormalizedItem("476", "anime", title, summary, releaseYear,
                null, null, null, null,
                null, null, null,
                coverUrl,
                tagsJson, rating,
                rating == null ? null : "0-10",
                rating == null ? null : "otaku_site", null);
    }

    /** 只带 source_url 的旧记录，其余可空字段都为 null，便于隔离验证。 */
    private static WorkRecord workWithSourceUrl(String sourceUrl) {
        return new WorkRecord(1L, "W-test", "anime", "原标题", null, null,
                null, null, null, null,
                "http://154.8.194.198:8000/media/full/cover_1.jpg", "cache-key", T,
                null, null, null, null, "otaku_site", "476", sourceUrl, T, T);
    }

    /** 带 source_url 的条目，其余字段与 {@link #item} 一致。 */
    private static NormalizedItem itemWithSourceUrl(String sourceUrl) {
        return new NormalizedItem("476", "anime", "原标题", null, null,
                null, null, null, null,
                null, null, null,
                null, null, null, null, null, sourceUrl);
    }

    @Test
    @DisplayName("可空字段全为 null 时不覆盖，且计为未变化")
    void nullDoesNotOverwrite() {
        WorkRecord old = work("旧简介", "[\"日常\"]", "7.80");

        WorkMerger.MergeResult result = WorkMerger.merge(old, item("原标题", null, null, null, null));

        assertThat(result.changed()).isFalse();
        assertThat(result.work().summary()).isEqualTo("旧简介");
        assertThat(result.work().tagsJson()).isEqualTo("[\"日常\"]");
        assertThat(result.work().ratingValue()).isEqualByComparingTo("7.80");
        assertThat(result.work().updatedAt()).isEqualTo(T);
    }

    @Test
    @DisplayName("只更新本次提供的字段，其余保持原值")
    void updatesOnlyProvidedFields() {
        WorkRecord old = work("旧简介", "[\"日常\"]", "7.80");

        WorkMerger.MergeResult result = WorkMerger.merge(old, item("新标题", null, null, "9.1", null));

        assertThat(result.changed()).isTrue();
        assertThat(result.work().title()).isEqualTo("新标题");
        assertThat(result.work().summary()).isEqualTo("旧简介");
        assertThat(result.work().tagsJson()).isEqualTo("[\"日常\"]");
        assertThat(result.work().ratingValue()).isEqualByComparingTo("9.10");
        assertThat(result.work().updatedAt()).isAfter(T);
    }

    @Test
    @DisplayName("tags 传 [] 表示明确无标签，可以清空")
    void emptyTagsClears() {
        WorkRecord old = work("旧简介", "[\"日常\",\"搞笑\"]", "7.80");

        WorkMerger.MergeResult result = WorkMerger.merge(old, item("原标题", null, "[]", null, null));

        assertThat(result.changed()).isTrue();
        assertThat(result.work().tagsJson()).isEqualTo("[]");
    }

    @Test
    @DisplayName("work_id 不随内容变化")
    void workIdNeverChanges() {
        WorkRecord old = work("旧简介", null, "7.80");

        WorkMerger.MergeResult result = WorkMerger.merge(old, item("换了个标题", "新简介", null, "9.1", null));

        assertThat(result.work().workId()).isEqualTo("W-test");
        assertThat(result.work().sourceId()).isEqualTo("476");
        assertThat(result.work().createdAt()).isEqualTo(T);
    }

    @Test
    @DisplayName("评分只是小数位表示不同（7.8 vs 7.80）不算变化")
    void decimalScaleIsNotAChange() {
        WorkRecord old = work("旧简介", null, "7.80");

        WorkMerger.MergeResult result = WorkMerger.merge(old, item("原标题", null, null, "7.8", null));

        assertThat(result.changed()).isFalse();
    }

    @Test
    @DisplayName("封面地址变化要清掉本地缓存键，强制重新回源")
    void coverChangeInvalidatesCache() {
        WorkRecord old = work("旧简介", null, "7.80");

        WorkMerger.MergeResult result = WorkMerger.merge(old,
                item("原标题", null, null, null, "http://154.8.194.198:8000/media/full/cover_2.jpg"));

        assertThat(result.changed()).isTrue();
        assertThat(result.work().coverCacheKey()).isNull();
        assertThat(result.work().coverCachedAt()).isNull();
        assertThat(result.work().coverSourceUrl()).contains("cover_2.jpg");
    }

    @Test
    @DisplayName("新建记录带 work_id，创建与更新时间一致")
    void newRecordHasWorkId() {
        WorkRecord created = WorkMerger.newRecord(
                item("标题", "简介", "[\"日常\"]", "7.8", null), "W-new", "otaku_site", T);

        assertThat(created.workId()).isEqualTo("W-new");
        assertThat(created.source()).isEqualTo("otaku_site");
        assertThat(created.id()).isNull();
        assertThat(created.createdAt()).isEqualTo(T);
        assertThat(created.updatedAt()).isEqualTo(T);
    }

    @Test
    @DisplayName("source_url 提供新值时覆盖，并计入变化")
    void sourceUrlIsUpdated() {
        WorkRecord old = workWithSourceUrl("https://old.example/1");

        WorkMerger.MergeResult result = WorkMerger.merge(
                old, itemWithSourceUrl("https://bgm.tv/subject/476"));

        assertThat(result.changed()).isTrue();
        assertThat(result.work().sourceUrl()).isEqualTo("https://bgm.tv/subject/476");
    }

    @Test
    @DisplayName("source_url 为 null 时保留旧值，不推进 updated_at")
    void sourceUrlNullKeepsOld() {
        WorkRecord old = workWithSourceUrl("https://old.example/1");

        WorkMerger.MergeResult result = WorkMerger.merge(old, itemWithSourceUrl(null));

        assertThat(result.changed()).isFalse();
        assertThat(result.work().sourceUrl()).isEqualTo("https://old.example/1");
        assertThat(result.work().updatedAt()).isEqualTo(T);
    }

    @Test
    @DisplayName("新建时年份直接落库")
    void newRecordCarriesReleaseYear() {
        WorkRecord created = WorkMerger.newRecord(
                item("标题", null, null, null, null, 1995), "W-new", "otaku_site", T);

        assertThat(created.releaseYear()).isEqualTo(1995);
    }

    @Test
    @DisplayName("年份为 null 不覆盖已有值——来源这条没给年份，别把历史值抹掉")
    void nullYearDoesNotOverwrite() {
        WorkRecord old = work("旧简介", null, null, 1995);

        WorkMerger.MergeResult result = WorkMerger.merge(old, item("原标题", null, null, null, null));

        assertThat(result.changed()).isFalse();
        assertThat(result.work().releaseYear()).isEqualTo(1995);
    }

    @Test
    @DisplayName("年份变了要算变化，并推进 updated_at")
    void releaseYearChangeCounts() {
        WorkRecord old = work("旧简介", null, null, 1995);

        WorkMerger.MergeResult result = WorkMerger.merge(old, item("原标题", null, null, null, null, 1996));

        assertThat(result.changed()).isTrue();
        assertThat(result.work().releaseYear()).isEqualTo(1996);
        assertThat(result.work().updatedAt()).isAfter(T);
    }

    @Test
    @DisplayName("年份相同不算变化——否则每次全量同步都会把 unchanged 变成 updated")
    void sameYearIsNotAChange() {
        WorkRecord old = work("旧简介", null, null, 1995);

        WorkMerger.MergeResult result = WorkMerger.merge(old, item("原标题", null, null, null, null, 1995));

        assertThat(result.changed()).isFalse();
    }
}
