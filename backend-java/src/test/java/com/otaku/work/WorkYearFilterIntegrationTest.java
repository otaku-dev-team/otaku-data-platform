package com.otaku.work;

import com.otaku.importer.ImportService;
import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchRequest.ImportItem;
import com.otaku.work.dto.WorkSummaryDto;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * 年份筛选（{@code GET /api/works?year=}）。
 *
 * <p>为什么必须连真库：这里验的是 SQL 的三条路径——主表等值过滤、
 * {@code work_tag} 冗余列过滤（不回表）、以及两者与 {@code sort} 的组合。
 * Mock 掉仓储等于只测了「参数传下去了没有」，测不到「筛出来的是不是对的那批」。
 *
 * <p>重点不在「能筛出来」，而在**边界**：
 * 没有年份的条目必须被排除（不能混进某一年的结果），
 * 以及**总数缓存不能把 A 年的总数串给 B 年**——后者是加这个参数最容易漏的坑。
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class WorkYearFilterIntegrationTest {

    private static final String ID_PREFIX = "it-year-";
    private static final String BATCH_PREFIX = "it-year-batch-";
    private static final String TAG = "it-year-tag";

    @Autowired
    private ImportService importService;

    @Autowired
    private WorkService workService;

    @Autowired
    private CountCache countCache;

    @Autowired
    private JdbcTemplate jdbc;

    @AfterEach
    void cleanUp() {
        countCache.invalidateAll();
        jdbc.update("DELETE FROM work_tag WHERE work_ref IN"
                + " (SELECT id FROM work WHERE source_id LIKE ?)", ID_PREFIX + "%");
        jdbc.update("DELETE FROM import_batch_run WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM import_batch WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM work WHERE source_id LIKE ?", ID_PREFIX + "%");
    }

    @Test
    @DisplayName("按年份筛：只返回该年，且没有年份的条目被排除")
    void filtersByYearAndExcludesUnknown() {
        importBatch(
                item("a", "2022 年的作品", 2022, null),
                item("b", "另一部 2022", 2022, null),
                item("c", "2021 年的作品", 2021, null),
                item("d", "不知道哪一年", null, null));

        var y2022 = workService.list(null, KEYWORD, null, null, null, null, "2022", 1, 50);
        assertThat(y2022.total()).isEqualTo(2);
        assertThat(y2022.items()).extracting(WorkSummaryDto::workId)
                .containsExactlyInAnyOrder(workIdOf("a"), workIdOf("b"));

        // 关键边界：没年份的不能被算进任何一年。若实现写成「= :year OR release_year IS NULL」，
        // 用户点 2022 会看到一部不知道哪年的片子，且他无法分辨。
        assertThat(workService.list(null, KEYWORD, null, null, null, null, "2022", 1, 50).items())
                .extracting(WorkSummaryDto::workId)
                .doesNotContain(workIdOf("d"));

        assertThat(workService.list(null, KEYWORD, null, null, null, null, "2021", 1, 50).items())
                .extracting(WorkSummaryDto::workId)
                .containsExactly(workIdOf("c"));
    }

    @Test
    @DisplayName("总数缓存不能串年份：先查 2022 再查 2021，各自的总数必须对")
    void countCacheDoesNotLeakAcrossYears() {
        importBatch(
                item("e", "2022 甲", 2022, null),
                item("f", "2022 乙", 2022, null),
                item("g", "2021 丙", 2021, null));

        // 顺序很重要：先 2022（2 条）把缓存填上，再问 2021。
        // 若 CountCache 的键漏了 year，2021 会拿到 2——而正确答案是 1。
        assertThat(workService.list(null, KEYWORD, null, null, null, null, "2022", 1, 50).total())
                .isEqualTo(2);
        assertThat(workService.list(null, KEYWORD, null, null, null, null, "2021", 1, 50).total())
                .as("缓存键漏了 year 就会串成 2")
                .isEqualTo(1);
        // 不带 year 时又是另一个总数，同样不能被上面两次污染。
        assertThat(workService.list(null, KEYWORD, null, null, null, null, null, 1, 50).total())
                .isEqualTo(3);
    }

    @Test
    @DisplayName("标签 + 年份：走 work_tag 的冗余列，结果与主表路径一致")
    void filtersByYearOnTagPath() {
        importBatch(
                item("h", "标签内 2022", 2022, List.of(TAG)),
                item("i", "标签内 2021", 2021, List.of(TAG)),
                item("j", "标签内无年份", null, List.of(TAG)));

        // 没有 q 时走的是 work_tag 冗余列这条路径（不回表）。
        var tagged = workService.list(null, null, TAG, null, null, null, "2022", 1, 50);
        assertThat(tagged.total()).isEqualTo(1);
        assertThat(tagged.items()).extracting(WorkSummaryDto::workId)
                .containsExactly(workIdOf("h"));

        // 带 q 时会 JOIN 回 work 走主表条件——两条路径必须给同一个答案。
        var taggedWithKeyword = workService.list(null, "标签内", TAG, null, null, null, "2022", 1, 50);
        assertThat(taggedWithKeyword.total())
                .as("主表路径与索引路径对同一个筛选必须一致")
                .isEqualTo(1);
        assertThat(taggedWithKeyword.items()).extracting(WorkSummaryDto::workId)
                .containsExactly(workIdOf("h"));
    }

    @Test
    @DisplayName("年份与 sort 可以同时用：sort 定顺序、year 定结果集")
    void yearAndSortCompose() {
        importBatch(
                item("k", "2022 低分", 2022, null, "5.0"),
                item("l", "2022 高分", 2022, null, "9.0"),
                item("m", "2021 更高分", 2021, null, "9.9"));

        var page = workService.list(null, KEYWORD, null, null, "rating", null, "2022", 1, 50);

        assertThat(page.total()).isEqualTo(2);
        // 只含 2022 的两条，且按评分降序——2021 那条分数最高但不在结果里。
        assertThat(page.items()).extracting(WorkSummaryDto::workId)
                .containsExactly(workIdOf("l"), workIdOf("k"));
    }

    @Test
    @DisplayName("这一年没有作品：200 + 空数组，不是错误")
    void emptyYearIsNotAnError() {
        importBatch(item("n", "只有 2022", 2022, null));

        var page = workService.list(null, KEYWORD, null, null, null, null, "1999", 1, 50);
        assertThat(page.total()).isZero();
        assertThat(page.items()).isEmpty();
    }

    @Test
    @DisplayName("非法年份返回 400：与「这一年没有作品」区分开")
    void rejectsInvalidYear() {
        assertBadRequest("abc");
        assertBadRequest("2022.5");
        assertBadRequest("1899");
        assertBadRequest("2101");
    }

    @Test
    @DisplayName("空串等价于不过滤（前端清空筛选时发空串不该报错）")
    void blankYearMeansNoFilter() {
        importBatch(
                item("o", "2022 一条", 2022, null),
                item("p", "2021 一条", 2021, null));

        assertThat(workService.list(null, KEYWORD, null, null, null, null, "  ", 1, 50).total())
                .isEqualTo(2);
    }

    // ---------------------------------------------------------------- helpers

    private static final String KEYWORD = "ITYEAR";

    private void assertBadRequest(String year) {
        assertThatThrownBy(() -> workService.list(null, KEYWORD, null, null, null, null, year, 1, 20))
                .isInstanceOf(com.otaku.common.ApiException.class)
                .satisfies(ex -> assertThat(((com.otaku.common.ApiException) ex).code())
                        .isEqualTo(com.otaku.common.ErrorCode.BAD_REQUEST));
    }

    private String workIdOf(String sourceSuffix) {
        return jdbc.queryForObject(
                "SELECT work_id FROM work WHERE source_id = ?", String.class,
                ID_PREFIX + sourceSuffix);
    }

    private ImportItem item(String suffix, String title, Integer year, List<String> tags) {
        return item(suffix, title, year, tags, null);
    }

    private ImportItem item(String suffix, String title, Integer year, List<String> tags, String rating) {
        return new ImportItem(
                ID_PREFIX + suffix,
                "anime",
                KEYWORD + " " + title,
                null,
                null,
                year,
                tags == null ? List.of() : tags,
                rating == null
                        ? null
                        : new ImportBatchRequest.SourceRating(new java.math.BigDecimal(rating), "0-10", "otaku_site"),
                null, null, null, null, null, null, null, null);
    }

    private void importBatch(ImportItem... items) {
        importService.importBatch(new ImportBatchRequest(
                BATCH_PREFIX + System.nanoTime(), "otaku_site", null, List.of(items)));
    }
}
