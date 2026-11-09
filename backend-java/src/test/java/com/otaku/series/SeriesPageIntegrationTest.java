package com.otaku.series;

import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.importer.ImportService;
import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchRequest.ImportItem;
import com.otaku.importer.dto.ImportBatchRequest.SourceRating;
import com.otaku.series.dto.SeriesPageDto;
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
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * 系列页端点（#557）：排序、total、name 的三态、404 的判据。
 *
 * <p>为什么必须连真库：验的是 `work.series_key` 上的反查 + `series` 表的名字 + 可见性过滤，
 * 三条都是 SQL 语义；而且排序键 `rating_sort` 是**生成列**，mock 里根本不存在。
 *
 * <p>三类「不存在」要分开（第 4 组用例）：
 * 有系列行有作品 / 有作品没系列行 / 系列行和作品都没有。
 * 只有最后一种才是 404——中间那种是**常态**（数据集两张表分开导入），给 404 会让
 * 刚导入的系列整页打不开。
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class SeriesPageIntegrationTest {

    private static final String ID_PREFIX = "it-serpage-";
    private static final String BATCH_PREFIX = "it-serpage-batch-";
    private static final String SOURCE = "otaku_site";
    private static final String KEY = "it-serpage-s1";

    @Autowired
    private SeriesService service;

    @Autowired
    private ImportService importService;

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
    @DisplayName("系列页：按评分降序（不是年代），total 是总数，name 来自 series 表")
    void pageOrdersByRatingNotYear() {
        importBatch(List.of(
                item("old", "第一季", 2017, 7.5, KEY, "物语系列"),
                item("new", "第二季", 2019, 9.0, KEY, "物语系列"),
                item("mid", "总集篇", 2018, 8.0, KEY, "物语系列")));

        SeriesPageDto page = service.page(KEY, 60, 0);

        assertThat(page.key()).isEqualTo(KEY);
        assertThat(page.name()).isEqualTo("物语系列");
        assertThat(page.total()).isEqualTo(3);
        assertThat(page.items()).extracting(WorkSummaryDto::title)
                .as("目录页按评分：与详情页区块的「年代升序」刻意不同")
                .containsExactly("第二季", "总集篇", "第一季");
    }

    @Test
    @DisplayName("超过一页时头部数字是总数，不是截断后的长度（首站的老 bug）")
    void totalIsNotPageLength() {
        importBatch(List.of(
                item("a", "A", 2020, 9.0, KEY, "长系列"),
                item("b", "B", 2020, 8.0, KEY, "长系列"),
                item("c", "C", 2020, 7.0, KEY, "长系列")));

        SeriesPageDto page = service.page(KEY, 2, 0);

        assertThat(page.items()).hasSize(2);
        assertThat(page.total()).as("客户端头部显示的是这个数").isEqualTo(3);
    }

    @Test
    @DisplayName("有作品、没有系列行：200 + name=null（不是 404）；只给 key 不给名也照样出页")
    void worksWithoutSeriesRowIsNot404() {
        importBatch(List.of(
                item("a", "A", 2020, 9.0, KEY, null),
                item("b", "B", 2021, 8.0, KEY, null)));

        SeriesPageDto page = service.page(KEY, 60, 0);

        assertThat(page.name()).as("客户端应隐藏标题，不要拿 key 顶替").isNull();
        assertThat(page.total()).isEqualTo(2);
        assertThat(page.items()).hasSize(2);
    }

    @Test
    @DisplayName("系列行和可见作品都没有 → 404 SERIES_NOT_FOUND；key 超长也 404")
    void unknownSeriesIs404() {
        assertThatThrownBy(() -> service.page("it-serpage-nope", 60, 0))
                .isInstanceOf(ApiException.class)
                .satisfies(ex -> assertThat(((ApiException) ex).code())
                        .isEqualTo(ErrorCode.SERIES_NOT_FOUND));
        assertThatThrownBy(() -> service.page("x".repeat(65), 60, 0))
                .isInstanceOf(ApiException.class)
                .satisfies(ex -> assertThat(((ApiException) ex).code())
                        .isEqualTo(ErrorCode.SERIES_NOT_FOUND));
        assertThatThrownBy(() -> service.page(null, 60, 0))
                .isInstanceOf(ApiException.class);
    }

    @Test
    @DisplayName("已下架的作品不出现，也不计入 total；分页越界给空数组")
    void deletedWorkIsExcluded() {
        importBatch(List.of(
                item("live", "在架", 2020, 8.0, KEY, "物语系列"),
                item("gone", "已下架", 2021, 9.0, KEY, "物语系列")));
        jdbc.update("UPDATE work SET deleted_at = NOW(3) WHERE source_id = ?", ID_PREFIX + "gone");

        SeriesPageDto page = service.page(KEY, 60, 0);
        assertThat(page.total()).isEqualTo(1);
        assertThat(page.items()).extracting(WorkSummaryDto::title).containsExactly("在架");

        SeriesPageDto beyond = service.page(KEY, 60, 10);
        assertThat(beyond.total()).isEqualTo(1);
        assertThat(beyond.items()).isEmpty();
    }

    @Test
    @DisplayName("详情页区块与系列页的排序不同：区块按年代、页面按评分")
    void sectionKeepsChronologicalOrder() {
        importBatch(List.of(
                item("old", "第一季", 2017, 7.5, KEY, "物语系列"),
                item("new", "第二季", 2019, 9.0, KEY, "物语系列")));

        String newWorkId = jdbc.queryForObject("SELECT work_id FROM work WHERE source_id = ?",
                String.class, ID_PREFIX + "new");

        assertThat(service.of(newWorkId).items()).extracting(item -> item.work().title())
                .as("详情页区块是观看顺序：第一季在前")
                .containsExactly("第一季", "第二季");
        assertThat(service.page(KEY, 60, 0).items()).extracting(WorkSummaryDto::title)
                .as("系列页是「哪几部最好看」：评分高的在前")
                .containsExactly("第二季", "第一季");
    }

    // ------------------------------------------------------------------

    private ImportItem item(String suffix, String title, Integer year, double rating,
                            String seriesKey, String seriesName) {
        return new ImportItem(ID_PREFIX + suffix, "anime", title, null, null, year, null,
                new SourceRating(BigDecimal.valueOf(rating), "0-10", SOURCE), null,
                null, null, null, null, null, null, null, seriesKey, seriesName);
    }

    private void importBatch(List<ImportItem> items) {
        importService.importBatch(new ImportBatchRequest(
                BATCH_PREFIX + System.nanoTime(), SOURCE, OffsetDateTime.now(ZoneOffset.UTC), items));
    }
}
