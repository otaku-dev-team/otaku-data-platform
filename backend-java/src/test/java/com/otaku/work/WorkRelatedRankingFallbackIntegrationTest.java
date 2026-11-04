package com.otaku.work;

import com.otaku.importer.ImportService;
import com.otaku.importer.dto.ImportBatchRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;

import java.util.List;

import static com.otaku.work.WorkRelatedRankingIntegrationTest.item;
import static org.assertj.core.api.Assertions.assertThat;

/**
 * 同一条排序口径在**按站收口关闭**时的分支：召回仍用 {@code work.tags} 的 JSON 交集，
 * 只用 {@code work_tag} 打分。
 *
 * <p>为什么单独一个类：两套 SQL 是不同的召回来源（标签索引 vs JSON 交集），
 * 只测其中一条，另一条就会在「以后关掉收口」时静默退化成按评分排。
 */
@SpringBootTest(properties = "app.work.site-scope.enabled=false")
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class WorkRelatedRankingFallbackIntegrationTest {

    private static final String SOURCE = "it-related-fb-src";
    private static final String BATCH = "it-related-fb-batch-";

    private static final String BASE_ID = "990201";
    private static final String NEAR_ID = "990202";
    private static final String FAR_ID = "990203";

    @Autowired
    private ImportService importService;

    @Autowired
    private WorkService workService;

    @Autowired
    private WorkRepository workRepository;

    @Autowired
    private JdbcTemplate jdbc;

    @BeforeEach
    void setUp() {
        cleanUp();
        importService.importBatch(new ImportBatchRequest(BATCH + "1", SOURCE, null, List.of(
                item(BASE_ID, "回退基准", List.of("回退甲", "回退乙", "回退丙"), 8),
                item(NEAR_ID, "回退近邻", List.of("回退甲", "回退乙", "回退丁"), 6),
                item(FAR_ID, "回退远邻", List.of("回退甲", "回退戊", "回退己"), 9))));
    }

    @AfterEach
    void cleanUp() {
        jdbc.update("DELETE FROM work_tag WHERE work_ref IN (SELECT id FROM work WHERE source = ?)", SOURCE);
        jdbc.update("DELETE FROM work WHERE source = ?", SOURCE);
        jdbc.update("DELETE FROM import_batch_run WHERE batch_id LIKE ?", BATCH + "%");
        jdbc.update("DELETE FROM import_batch WHERE batch_id LIKE ?", BATCH + "%");
    }

    @Test
    @DisplayName("收口关闭时同样按共享标签数排，不是退回纯评分")
    void fallbackPathAlsoRanksBySharedTags() {
        String baseWorkId = workRepository.findBySourceKey(SOURCE, BASE_ID).orElseThrow().workId();

        var related = workService.related(baseWorkId, 10);

        assertThat(related.items()).extracting(i -> i.title())
                .containsSubsequence("回退近邻", "回退远邻");
    }
}
