package com.otaku.work;

import com.otaku.collection.CollectionRepository;
import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.importer.ImportService;
import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchRequest.ImportItem;
import com.otaku.importer.dto.ImportBatchRequest.SourceRating;
import com.otaku.schedule.ScheduleRepository;
import com.otaku.schedule.ScheduleRecord;
import com.otaku.schedule.ScheduleService;
import com.otaku.schedule.dto.ScheduleDtos.ScheduleItem;
import com.otaku.work.dto.WorkSummaryDto;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * 成人内容对外不可见：一条成人作品在**六条对外路径**上都必须消失。
 *
 * <p>为什么必须连真库：判定依赖 {@code is_adult} 落库列（在 {@code replaceTags} 里由
 * {@code JSON_TABLE} + {@code IN} 列表写进去），过滤依赖各条 SQL 的条件——Mock 掉仓储
 * 等于什么也没验。纯 Java 的判定规则见 {@link com.otaku.common.AdultTagsTest}。
 *
 * <p>断言都比的是「自己的样本」而不是全库总数：集成测试库里可能还有别的用例留下的数据，
 * 用全库条数做期望值会随执行顺序变红（这条教训来自 WorkTagFilterIntegrationTest）。
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class AdultContentVisibilityIntegrationTest {

    private static final String ID_PREFIX = "it-adult-";
    private static final String BATCH_PREFIX = "it-adult-batch-";
    /** 只属于本用例的标签，避免撞上库里已有作品（列表 / 词表 / 推荐都靠它定位样本）。 */
    private static final String SAMPLE_TAG = "it成人遮挡样本";
    private static final String SEASON = "it-2099S1";

    @Autowired
    private ImportService importService;

    @Autowired
    private WorkService workService;

    @Autowired
    private TagService tagService;

    @Autowired
    private ScheduleService scheduleService;

    @Autowired
    private ScheduleRepository scheduleRepository;

    @Autowired
    private CollectionRepository collectionRepository;

    @Autowired
    private JdbcTemplate jdbc;

    @AfterEach
    void cleanUp() {
        jdbc.update("DELETE FROM collection WHERE work_id IN"
                + " (SELECT work_id FROM work WHERE source_id LIKE ?)", ID_PREFIX + "%");
        jdbc.update("DELETE FROM collection WHERE user_id IN (SELECT id FROM app_user WHERE user_id LIKE ?)",
                ID_PREFIX + "%");
        jdbc.update("DELETE FROM app_user WHERE user_id LIKE ?", ID_PREFIX + "%");
        jdbc.update("DELETE FROM schedule WHERE source_id LIKE ?", ID_PREFIX + "%");
        // work_tag 没有外键，必须先清，否则会留下悬空引用
        jdbc.update("DELETE FROM work_tag WHERE work_ref IN"
                + " (SELECT id FROM work WHERE source_id LIKE ?)", ID_PREFIX + "%");
        jdbc.update("DELETE FROM work WHERE source_id LIKE ?", ID_PREFIX + "%");
        jdbc.update("DELETE FROM import_batch_run WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM import_batch WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
    }

    @Test
    @DisplayName("导入即打标：成人作品的 work.is_adult 与 work_tag.is_adult 都由标签推出")
    void importMarksAdultFlag() {
        importBatch(
                item("it-adult-1", "正常作品", List.of(SAMPLE_TAG), "8.0"),
                item("it-adult-2", "成人作品", List.of(SAMPLE_TAG, "R18", "拔作"), "8.0"));

        assertThat(adultFlagOf("it-adult-1")).isZero();
        assertThat(adultFlagOf("it-adult-2")).isEqualTo(1);
        assertThat(adultTagRowsOf("it-adult-2"))
                .as("作品是成人内容 → 它的每一行都标 1，不只是 R18 那一行（否则词表计数漏过滤）")
                .isEqualTo(3);
        assertThat(adultTagRowsOf("it-adult-1")).isZero();
    }

    @Test
    @DisplayName("列表 / 总数 / 详情 / 相关推荐：成人作品一条都不出")
    void listDetailAndRelatedExcludeAdultWorks() {
        importBatch(
                item("it-adult-3", "正常作品", List.of(SAMPLE_TAG), "8.0"),
                item("it-adult-4", "成人作品", List.of(SAMPLE_TAG, "R18"), "9.9"));

        var page = workService.list(null, null, SAMPLE_TAG, null, null, null, null, 1, 50);
        assertThat(page.total()).as("总数不能把成人作品算进去").isEqualTo(1);
        assertThat(page.items())
                .extracting(WorkSummaryDto::workId)
                .containsExactly(workIdOf("it-adult-3"));

        // 详情：与不存在同一个错误码，不泄漏「这部片子存在但被藏了」
        assertThatThrownBy(() -> workService.detail(workIdOf("it-adult-4")))
                .isInstanceOf(ApiException.class)
                .satisfies(ex -> assertThat(((ApiException) ex).code()).isEqualTo(ErrorCode.WORK_NOT_FOUND));

        // 相关推荐：两部作品共享 SAMPLE_TAG，正常作品唯一的候选被过滤后应当是空
        var related = workService.related(workIdOf("it-adult-3"), 20);
        assertThat(related.items()).isEmpty();
    }

    @Test
    @DisplayName("标签词表：成人词不出现，正常词的计数不把成人作品算进去")
    void tagVocabularyDropsAdultWordsAndHiddenCounts() {
        importBatch(
                item("it-adult-5", "正常作品", List.of(SAMPLE_TAG), "8.0"),
                item("it-adult-6", "成人作品", List.of(SAMPLE_TAG, "R18"), "8.0"));

        var vocabulary = tagService.list(null, null).items();
        assertThat(vocabulary).extracting(item -> item.name())
                .doesNotContain("R18", "拔作", "里番", "成年コミック");
        assertThat(vocabulary)
                .filteredOn(item -> SAMPLE_TAG.equals(item.name()))
                .singleElement()
                .extracting(item -> item.count())
                .as("两部作品带这个标签，但只有一部可见")
                .isEqualTo(1L);
    }

    @Test
    @DisplayName("收藏列表：已收藏的成人作品不出现，总数与列表同口径")
    void collectionListHidesAdultWorks() {
        importBatch(
                item("it-adult-7", "正常作品", List.of(SAMPLE_TAG), "8.0"),
                item("it-adult-8", "成人作品", List.of(SAMPLE_TAG, "R18"), "8.0"));
        long userPk = createUser("it-adult-user-1");
        collect(userPk, workIdOf("it-adult-7"));
        collect(userPk, workIdOf("it-adult-8"));

        var rows = collectionRepository.findPage(userPk, null, 50, 0);

        assertThat(rows).extracting(row -> row.workId()).containsExactly(workIdOf("it-adult-7"));
        assertThat(collectionRepository.count(userPk, null)).isEqualTo(1);
    }

    @Test
    @DisplayName("档期：带成人标签的条目整条不返回，正常条目照常返回")
    void scheduleHidesAdultEntries() {
        insertSchedule("it-adult-9", "正常档期", List.of("日常", "TV"));
        insertSchedule("it-adult-10", "成人档期", List.of("日常", "R18"));

        List<ScheduleItem> items = scheduleService.list(SEASON).groups().stream()
                .flatMap(group -> group.items().stream())
                .toList();

        assertThat(items).extracting(ScheduleItem::titleMain).containsExactly("正常档期");
        assertThat(items).allSatisfy(item ->
                assertThat(item.workTags()).doesNotContain("R18"));
    }

    // ---------------------------------------------------------------- helpers

    private void importBatch(ImportItem... items) {
        importService.importBatch(new ImportBatchRequest(
                BATCH_PREFIX + UUID.randomUUID(), "otaku_site", null, List.of(items)));
    }

    private static ImportItem item(String sourceId, String title, List<String> tags, String rating) {
        return new ImportItem(
                sourceId, "anime", title, null, null, 2022, tags,
                rating == null ? null : new SourceRating(new BigDecimal(rating), "0-10", "otaku_site"),
                null, null, null, null, null, null, null, null);
    }

    private String workIdOf(String sourceId) {
        return jdbc.queryForObject(
                "SELECT work_id FROM work WHERE source_id = ?", String.class, sourceId);
    }

    private int adultFlagOf(String sourceId) {
        Integer flag = jdbc.queryForObject(
                "SELECT is_adult FROM work WHERE source_id = ?", Integer.class, sourceId);
        return flag == null ? 0 : flag;
    }

    private int adultTagRowsOf(String sourceId) {
        Integer n = jdbc.queryForObject(
                "SELECT COUNT(*) FROM work_tag WHERE is_adult = 1"
                        + " AND work_ref = (SELECT id FROM work WHERE source_id = ?)", Integer.class, sourceId);
        return n == null ? 0 : n;
    }

    private long createUser(String userId) {
        String username = userId + "-" + UUID.randomUUID().toString().substring(0, 8);
        jdbc.update("INSERT INTO app_user (user_id, username, password_hash, created_at, updated_at)"
                        + " VALUES (?, ?, ?, ?, ?)",
                userId, username, "x", LocalDateTime.now(), LocalDateTime.now());
        Long id = jdbc.queryForObject("SELECT id FROM app_user WHERE user_id = ?", Long.class, userId);
        assertThat(id).isNotNull();
        return id;
    }

    private void collect(long userPk, String workId) {
        jdbc.update("INSERT INTO collection (user_id, work_id, status, created_at, updated_at)"
                        + " VALUES (?, ?, ?, ?, ?)",
                userPk, workId, "wish", LocalDateTime.now(), LocalDateTime.now());
    }

    private void insertSchedule(String sourceId, String title, List<String> workTags) {
        String tagsJson;
        try {
            tagsJson = new com.fasterxml.jackson.databind.ObjectMapper().writeValueAsString(workTags);
        } catch (Exception ex) {
            throw new IllegalStateException(ex);
        }
        LocalDateTime now = LocalDateTime.now();
        scheduleRepository.insert(new ScheduleRecord(
                null, sourceId, "otaku_site", sourceId, SEASON,
                title, null, null, 1, "24:00", null, "anime",
                tagsJson, null, null, null, null, null, null, now, now));
    }
}
