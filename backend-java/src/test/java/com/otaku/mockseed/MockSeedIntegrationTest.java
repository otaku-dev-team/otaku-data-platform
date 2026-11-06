package com.otaku.mockseed;

import com.otaku.importer.ImportService;
import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchRequest.ImportItem;
import com.otaku.importer.dto.ImportBatchRequest.SourceRating;
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
import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * mock 种子在真库上的行为：**能写出四张表的数据**、**重复跑不会翻倍**、**清空只清 mock**。
 *
 * <p>为什么必须连真库：种子全是 SQL（批量插入、`ON DUPLICATE KEY`、按 identity_source 删），
 * Mock 掉 JdbcTemplate 等于什么都没验。
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class MockSeedIntegrationTest {

    private static final String SOURCE = "it-mock-src";
    private static final String BATCH = "it-mock-batch-";
    private static final String SITE_KEY = "it-seed-site";

    @Autowired
    private ImportService importService;

    @Autowired
    private MockSeedService service;

    @Autowired
    private JdbcTemplate jdbc;

    @BeforeEach
    void setUp() {
        cleanUp();
        // 站点是 mock 用户与评分的前置（app_user.site_key 外键指着 site；
        // ugc_review.site_key 非空）。dev 库里本来就有站点，测试库自己造一个。
        jdbc.update("INSERT IGNORE INTO site (site_key, display_name, status, created_at, updated_at,"
                + " ugc_enabled, ugc_moderation) VALUES (?, ?, 'active', NOW(3), NOW(3), 1, 'post')",
                SITE_KEY, "种子测试站");
        // 种子需要燃料：先造 30 部作品，每部 3 个标签，标签在 6 个里轮转
        List<String> tags = List.of("机甲", "日常", "奇幻", "悬疑", "音乐", "运动");
        List<ImportItem> items = new ArrayList<>();
        for (int i = 0; i < 30; i++) {
            items.add(new ImportItem("99" + String.format("%04d", 400 + i), "anime",
                    "种子测试作品 " + i, null, null, 2020,
                    List.of(tags.get(i % 6), tags.get((i + 1) % 6), tags.get((i + 2) % 6)),
                    new SourceRating(BigDecimal.valueOf(7 + i % 3), "0-10", "it"),
                    null, null, List.of(), null, null, null, null, null));
        }
        importService.importBatch(new ImportBatchRequest(BATCH + "1", SOURCE, null, items));
    }

    @AfterEach
    void cleanUp() {
        service.clear();
        jdbc.update("DELETE FROM site WHERE site_key = ?", SITE_KEY);
        jdbc.update("DELETE FROM work_tag WHERE work_ref IN (SELECT id FROM work WHERE source = ?)", SOURCE);
        jdbc.update("DELETE FROM work WHERE source = ?", SOURCE);
        jdbc.update("DELETE FROM import_batch_run WHERE batch_id LIKE ?", BATCH + "%");
        jdbc.update("DELETE FROM import_batch WHERE batch_id LIKE ?", BATCH + "%");
    }

    @Test
    @DisplayName("种 10 个用户：四张表都有数据，行为都落在最近 N 天内")
    void seedsAllFourTables() {
        MockSeedService.Result result = service.seed(10, 42, 60);

        assertThat(result.users()).isEqualTo(10);
        assertThat(result.views()).isGreaterThan(0);
        assertThat(result.collections()).isGreaterThan(0);
        assertThat(result.reviews()).isGreaterThan(0);

        assertThat(service.countMockUsers()).isEqualTo(10);
        Integer views = jdbc.queryForObject(
                "SELECT COUNT(*) FROM user_work_view v JOIN app_user u ON u.id = v.user_id"
                        + " WHERE u.identity_source = 'mock'", Integer.class);
        assertThat(views).isEqualTo(result.views());

        LocalDateTime oldest = jdbc.queryForObject(
                "SELECT MIN(first_viewed_at) FROM user_work_view v JOIN app_user u ON u.id = v.user_id"
                        + " WHERE u.identity_source = 'mock'", LocalDateTime.class);
        assertThat(oldest)
                .as("行为应落在最近 60 天内")
                .isAfter(LocalDateTime.now(ZoneOffset.UTC).minusDays(61));
    }

    @Test
    @DisplayName("同一个种子再跑一次：用户数不变，不会翻倍")
    void reseedingIsIdempotent() {
        MockSeedService.Result first = service.seed(10, 42, 60);
        MockSeedService.Result second = service.seed(10, 42, 60);

        assertThat(second.users()).isEqualTo(first.users());
        assertThat(service.countMockUsers()).isEqualTo(10);
        assertThat(second.views())
                .as("先清后种：第二次的浏览行数应与第一次一致，而不是累加")
                .isEqualTo(first.views());
    }

    @Test
    @DisplayName("清空只删 mock：真实用户一条不动")
    void clearOnlyRemovesMockUsers() {
        long realBefore = jdbc.queryForObject(
                "SELECT COUNT(*) FROM app_user WHERE identity_source IS NULL OR identity_source <> 'mock'",
                Long.class);
        service.seed(5, 7, 30);
        assertThat(service.countMockUsers()).isEqualTo(5);

        int removed = service.clear();

        assertThat(removed).isEqualTo(5);
        assertThat(service.countMockUsers()).isZero();
        assertThat(jdbc.queryForObject(
                "SELECT COUNT(*) FROM app_user WHERE identity_source IS NULL OR identity_source <> 'mock'",
                Long.class)).isEqualTo(realBefore);
    }
}
