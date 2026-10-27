package com.otaku.work;

import com.otaku.importer.ImportService;
import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchRequest.ImportItem;
import com.otaku.importer.dto.ImportBatchRequest.SourceRating;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * G2 的回归测试：**新接一个来源站不改任何后端代码**。
 *
 * <p>章程 §1 把「来源站接入成本趋近于零」写成 G2，但到 2026-10-24 为止这句话
 * 只有一个来源（otaku_site）在支撑它，属于**未被证伪也未被证实的假设**（W4）。
 * 真接第二站要站点配合，节奏不可控；这里先用一个虚构来源把「后端这一层是否真的
 * 与来源无关」钉住——它不能证明整条链路（适配器、清洗、限流在 Python 侧），
 * 但能保证**后端不偷偷把首站焊死**。
 *
 * <p>同一个类里也钉住**已知的边界**：{@code work_type} 仍是四值枚举，
 * 条目型之外的类型会被拒。这是契约约束（契约 §2.1），不是缺陷——
 * 写进测试是为了让「接第二个不同类型的站要改契约」这件事在 CI 里可见，
 * 而不是等真接的时候才发现。
 *
 * <p>没有 {@code IT_DB_PORT} 时整类跳过；CI 注入 {@code IT_DB_PORT=3306} 真跑。
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "第二阶段来源的回归测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class SecondSourceIntegrationTest {

    /** 虚构第二来源：故意不用 otaku_site / bangumi，避免和真实数据混淆。 */
    private static final String SOURCE = "it-second-site";
    private static final String ID_PREFIX = "it2-";
    private static final String BATCH_PREFIX = "it2-batch-";

    @Autowired
    private ImportService importService;

    @Autowired
    private WorkService workService;

    @Autowired
    private JdbcTemplate jdbc;

    @AfterEach
    void cleanUp() {
        jdbc.update("DELETE FROM work_tag WHERE work_ref IN"
                + " (SELECT id FROM work WHERE source = ?)", SOURCE);
        jdbc.update("DELETE FROM import_batch_run WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM import_batch WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM work WHERE source = ?", SOURCE);
    }

    @Test
    @DisplayName("第二来源零后端改动：入库、列表、详情、标签筛选全部可用，source 透出正确")
    void secondSourceWorksWithoutBackendChange() {
        importBatch(item("it2-1", "anime", "第二站的作品", List.of("跨站样本"), "8.2"));

        var page = workService.list("anime", "第二站的作品", null, null, null, null, null, 1, 50);
        assertThat(page.total()).isEqualTo(1);
        var summary = page.items().get(0);
        assertThat(summary.title()).isEqualTo("第二站的作品");
        assertThat(summary.source()).as("列表必须透出来源，否则跨源同名分不开").isEqualTo(SOURCE);
        assertThat(summary.coverUrl()).as("没有封面地址时不该编造代理地址").isNull();

        var detail = workService.detail(summary.workId());
        assertThat(detail.source()).isEqualTo(SOURCE);
        assertThat(detail.sourceId()).isEqualTo("it2-1");

        var byTag = workService.list(null, null, "跨站样本", null, null, null, null, 1, 50);
        assertThat(byTag.items())
                .extracting(com.otaku.work.dto.WorkSummaryDto::workId)
                .contains(summary.workId());
    }

    @Test
    @DisplayName("两个来源的同名作品并存：都是独立记录，靠 source 区分，不互相覆盖")
    void sameTitleFromTwoSourcesCoexist() {
        importBatch(item("it2-2", "anime", "重名作品", null, "7.0"));
        // 首站也用同一个标题、同一个 source_id —— 唯一键是 (source, source_id)，两行都该在
        importService.importBatch(new ImportBatchRequest(
                "otaku_site", "otaku_site", null, List.of(item("it2-2", "anime", "重名作品", null, "9.0"))));

        var page = workService.list(null, "重名作品", null, null, null, null, null, 1, 50);
        assertThat(page.total()).as("两个来源各一条，不能被当成同一条改写").isEqualTo(2);
        assertThat(page.items()).extracting(com.otaku.work.dto.WorkSummaryDto::source)
                .containsExactlyInAnyOrder(SOURCE, "otaku_site");
        assertThat(page.items()).extracting(com.otaku.work.dto.WorkSummaryDto::workId)
                .doesNotHaveDuplicates();
    }

    @Test
    @DisplayName("已知边界：work_type 仍是四值枚举，新类型会被拒（接条目型第二站要改契约）")
    void unknownWorkTypeIsRejected() {
        var result = importService.importBatch(new ImportBatchRequest(
                BATCH_PREFIX + UUID.randomUUID(), SOURCE, null,
                List.of(item("it2-3", "book", "一本不是动画的书", null, null))));

        assertThat(result.counts().rejected()).isEqualTo(1);
        assertThat(result.errors())
                .extracting(com.otaku.importer.dto.ImportItemResult::code)
                .contains("INVALID_TYPE");
        assertThat(jdbc.queryForObject(
                "SELECT COUNT(*) FROM work WHERE source = ?", Integer.class, SOURCE))
                .as("被拒的记录不能落库").isZero();
    }

    // ---------------------------------------------------------------- helpers

    private void importBatch(ImportItem... items) {
        importService.importBatch(new ImportBatchRequest(
                BATCH_PREFIX + UUID.randomUUID(), SOURCE, null, List.of(items)));
    }

    private static ImportItem item(String sourceId, String workType, String title,
                                   List<String> tags, String rating) {
        return new ImportItem(
                sourceId, workType, title, null, null, 2024, tags,
                rating == null ? null : new SourceRating(new BigDecimal(rating), "0-10", "it-second-site"),
                null);
    }
}
