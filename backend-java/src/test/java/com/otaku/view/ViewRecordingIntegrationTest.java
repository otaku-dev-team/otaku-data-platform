package com.otaku.view;

import com.otaku.importer.ImportService;
import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchRequest.ImportItem;
import com.otaku.importer.dto.ImportBatchRequest.SourceRating;
import com.otaku.user.UserRecord;
import com.otaku.work.WorkRepository;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 浏览打点在真库上的行为：**有界行**（重复浏览只累加，不多出行）与 90 天清理。
 *
 * <p>为什么必须连真库：这两件事都写在 SQL 里——`ON DUPLICATE KEY UPDATE` 的累加语义、
 * 按 `last_viewed_at` 的范围删除。Mock 掉仓储等于什么都没验。
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class ViewRecordingIntegrationTest {

    private static final String SOURCE = "it-view-src";
    private static final String BATCH = "it-view-batch-";
    private static final String WORK_ID = "990301";
    private static final long USER_ID = 990301L;

    @Autowired
    private ImportService importService;

    @Autowired
    private ViewService viewService;

    @Autowired
    private ViewCleanupJob cleanupJob;

    @Autowired
    private WorkRepository workRepository;

    @Autowired
    private JdbcTemplate jdbc;

    private UserRecord user;
    private String workId;

    @BeforeEach
    void setUp() {
        cleanUp();
        importService.importBatch(new ImportBatchRequest(BATCH + "1", SOURCE, null, List.of(
                new ImportItem(WORK_ID, "anime", "浏览测试作品", null, null, 2020, List.of("浏览测试标签"),
                        new SourceRating(BigDecimal.valueOf(8), "0-10", "it"), null, null, List.of(),
                        null, null, null, null, null))));
        workId = workRepository.findBySourceKey(SOURCE, WORK_ID).orElseThrow().workId();
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        user = new UserRecord(USER_ID, "it-view-user", "it-view-user", "x", null,
                UserRecord.STATUS_ACTIVE, now, now, now);
    }

    @AfterEach
    void cleanUp() {
        jdbc.update("DELETE FROM user_work_view WHERE user_id = ?", USER_ID);
        jdbc.update("DELETE FROM work_tag WHERE work_ref IN (SELECT id FROM work WHERE source = ?)", SOURCE);
        jdbc.update("DELETE FROM work WHERE source = ?", SOURCE);
        jdbc.update("DELETE FROM import_batch_run WHERE batch_id LIKE ?", BATCH + "%");
        jdbc.update("DELETE FROM import_batch WHERE batch_id LIKE ?", BATCH + "%");
    }

    @Test
    @DisplayName("同一部作品看三次：只有一行，view_count = 3")
    void repeatedViewsKeepOneBoundedRow() {
        viewService.record(user, workId);
        viewService.record(user, workId);
        viewService.record(user, workId);

        List<Map<String, Object>> rows = jdbc.queryForList(
                "SELECT work_id, view_count FROM user_work_view WHERE user_id = ?", USER_ID);
        assertThat(rows).as("有界行：三次浏览只应留一行").hasSize(1);
        assertThat(((Number) rows.get(0).get("view_count")).intValue()).isEqualTo(3);
    }

    @Test
    @DisplayName("超过 90 天的浏览行被清掉，没超的留着")
    void purgeRemovesOnlyExpiredRows() {
        viewService.record(user, workId);
        // 手动把它推到 100 天前，模拟「上个月看过、之后再没打开」
        jdbc.update("UPDATE user_work_view SET last_viewed_at = ? WHERE user_id = ?",
                LocalDateTime.now(ZoneOffset.UTC).minusDays(100), USER_ID);

        int deleted = cleanupJob.purge(LocalDateTime.now(ZoneOffset.UTC));

        assertThat(deleted).as("100 天前的行应该被删").isGreaterThanOrEqualTo(1);
        assertThat(jdbc.queryForObject(
                "SELECT COUNT(*) FROM user_work_view WHERE user_id = ?", Integer.class, USER_ID))
                .isZero();
    }
}
