package com.otaku.work;

import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.importer.ImportService;
import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchRequest.ImportItem;
import com.otaku.importer.dto.ImportBatchResult;
import com.otaku.series.SeriesService;
import com.otaku.work.dto.WorkSeriesDto;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;

import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * 系列（#411）：导入落地 + `GET /api/works/{id}/series` 的反查口径。
 *
 * <p>为什么必须连真库：验的是「V37 的新列 + `series` 表的 upsert + 按 series_key 反查」，
 * 以及最危险的一条——**站点通道不带系列字段时不能把已有归属抹掉**。这三件事全是 SQL 语义，
 * mock 仓储只会证明 Java 分支跑过。
 *
 * <p>为什么走 ImportService 而不是直接 INSERT：系列是「导入时写进去的」，
 * 直接塞库只能证明查询对，证明不了写入对（`series` 行的 upsert、null 不覆盖）。
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class WorkSeriesIntegrationTest {

    private static final String ID_PREFIX = "it-series-";
    private static final String BATCH_PREFIX = "it-series-batch-";
    /** 已在站点注册的来源（导入会校验「来源必须登记」）。 */
    private static final String SOURCE = "otaku_site";
    private static final String SERIES_KEY = ID_PREFIX + "s1";

    @Autowired
    private ImportService importService;

    @Autowired
    private SeriesService seriesService;

    @Autowired
    private JdbcTemplate jdbc;

    @AfterEach
    void cleanUp() {
        jdbc.update("DELETE FROM import_batch_run WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM import_batch WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM work WHERE source_id LIKE ?", ID_PREFIX + "%");
        jdbc.update("DELETE FROM series WHERE series_key LIKE ?", ID_PREFIX + "%");
    }

    @Test
    @DisplayName("导入带系列的 3 部：反查按年代升序、年份未知沉底、包含当前作品、带系列名")
    void seriesRoundTrip() {
        importBatch(List.of(
                item("a", "第一季", 2017, SERIES_KEY, "物语系列"),
                item("b", "第二季", 2019, SERIES_KEY, "物语系列"),
                item("c", "总集篇", null, SERIES_KEY, "物语系列")));

        WorkSeriesDto series = seriesService.of(workIdOf("b"));

        assertThat(series.seriesKey()).isEqualTo(SERIES_KEY);
        assertThat(series.seriesName()).isEqualTo("物语系列");
        assertThat(series.items()).extracting(com.otaku.work.dto.WorkSummaryDto::title)
                .as("年份升序；年份未知的排最后（MySQL 的 ASC 会把 NULL 排最前，必须显式处理）")
                .containsExactly("第一季", "第二季", "总集篇");
        assertThat(series.items()).extracting(com.otaku.work.dto.WorkSummaryDto::workId)
                .as("当前作品也在清单里——系列是完整清单，客户端自己高亮")
                .contains(workIdOf("b"));
    }

    @Test
    @DisplayName("没有系列的作品：series_key / series_name 为 null、items 为空，不是 404")
    void workWithoutSeriesIsEmpty() {
        importBatch(List.of(item("solo", "独立作品", 2020, null, null)));

        WorkSeriesDto series = seriesService.of(workIdOf("solo"));

        assertThat(series.seriesKey()).isNull();
        assertThat(series.seriesName()).isNull();
        assertThat(series.items()).isEmpty();
    }

    @Test
    @DisplayName("站点通道不带系列字段（省略 = 不覆盖）：归属与名字都保留")
    void nullSeriesDoesNotOverwrite() {
        importBatch(List.of(item("keep", "第一季", 2017, SERIES_KEY, "物语系列")));

        // 第二次是站点 REST 通道的形状：两个字段都没有。
        ImportBatchResult second = importBatch(List.of(item("keep", "第一季", 2017, null, null)));

        assertThat(second.counts().unchanged()).as("没变化就不该算 updated").isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT series_key FROM work WHERE source_id = ?",
                String.class, ID_PREFIX + "keep")).isEqualTo(SERIES_KEY);
        assertThat(jdbc.queryForObject("SELECT name FROM series WHERE series_key = ?",
                String.class, SERIES_KEY)).isEqualTo("物语系列");
    }

    @Test
    @DisplayName("只给 key 不给名：系列行仍建立，名字保留旧值（不覆盖成 NULL）")
    void blankSeriesNameKeepsExistingName() {
        importBatch(List.of(item("named", "第一季", 2017, SERIES_KEY, "物语系列")));
        importBatch(List.of(item("named", "第一季", 2017, SERIES_KEY, null)));

        assertThat(jdbc.queryForObject("SELECT name FROM series WHERE series_key = ?",
                String.class, SERIES_KEY)).as("数据集偶尔只给 key 不给名").isEqualTo("物语系列");
    }

    @Test
    @DisplayName("只改系列归属：计为 updated（否则「重新导入了却没生效」且不报错）")
    void seriesOnlyChangeIsCountedAsUpdated() {
        importBatch(List.of(item("move", "第一季", 2017, SERIES_KEY, "物语系列")));

        ImportBatchResult moved = importBatch(List.of(
                item("move", "第一季", 2017, ID_PREFIX + "s2", "另一系列")));

        assertThat(moved.counts().updated()).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT series_key FROM work WHERE source_id = ?",
                String.class, ID_PREFIX + "move")).isEqualTo(ID_PREFIX + "s2");
    }

    @Test
    @DisplayName("已下架的作品不出现在兄弟列表里")
    void deletedSiblingIsExcluded() {
        importBatch(List.of(
                item("vis", "正片", 2017, SERIES_KEY, "物语系列"),
                item("deleted", "已下架", 2019, SERIES_KEY, "物语系列")));
        jdbc.update("UPDATE work SET deleted_at = NOW(3) WHERE source_id = ?", ID_PREFIX + "deleted");

        WorkSeriesDto series = seriesService.of(workIdOf("vis"));

        // 未收录（site_listed=0）那条不在这里验：IT 配置把 site-scope 关掉了
        // （见 application-it.yml 的说明），规则本身由 WorkSiteScopeIntegrationTest 覆盖。
        assertThat(series.items()).extracting(com.otaku.work.dto.WorkSummaryDto::title)
                .containsExactly("正片");
    }

    @Test
    @DisplayName("作品不存在 → 404 WORK_NOT_FOUND（与详情同一判据，不暴露「有这条但你看不到」）")
    void unknownWorkIs404() {
        assertThatThrownBy(() -> seriesService.of("W-not-exists"))
                .isInstanceOf(ApiException.class)
                .satisfies(ex -> assertThat(((ApiException) ex).code())
                        .isEqualTo(ErrorCode.WORK_NOT_FOUND));
    }

    // ------------------------------------------------------------------

    private ImportBatchResult importBatch(List<ImportItem> items) {
        return importService.importBatch(new ImportBatchRequest(
                BATCH_PREFIX + System.nanoTime(), SOURCE,
                OffsetDateTime.now(ZoneOffset.UTC), items));
    }

    private static ImportItem item(String suffix, String title, Integer year,
                                   String seriesKey, String seriesName) {
        return new ImportItem(ID_PREFIX + suffix, "anime", title, null, null, year, null, null,
                null, null, null, null, null, null, null, null, seriesKey, seriesName);
    }

    private String workIdOf(String suffix) {
        return jdbc.queryForObject("SELECT work_id FROM work WHERE source_id = ?",
                String.class, ID_PREFIX + suffix);
    }
}
