package com.otaku.work;

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
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 相关推荐的排序口径（relation-algorithm.md §6 的 P0）：**先看共享几个标签，再看评分**。
 *
 * <p>为什么必须连真库：这段排序整个在 SQL 里——标签索引的分组计数、与 work 的连接、
 * {@code JSON_TABLE} 的字符集。Mock 掉仓储只能证明 Java 把参数传对了，证明不了
 * 「共享 2 个标签的 6 分作品真的排在共享 1 个标签的 9 分作品前面」。
 *
 * <p>这个类跑的是**按站收口开启**的分支（生产形态）：召回和打分都走 {@code work_tag}。
 * 关闭收口的分支（JSON 召回 + 左连打分）由 {@link WorkRelatedRankingFallbackIntegrationTest} 覆盖。
 */
@SpringBootTest(properties = {
        "app.work.site-scope.enabled=true",
        // 自站来源不走收录清单：这个类只想测排序，不想再造一份 site_scope 数据
        "app.work.site-scope.self-sources=" + WorkRelatedRankingIntegrationTest.SOURCE})
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class WorkRelatedRankingIntegrationTest {

    static final String SOURCE = "it-related-src";
    private static final String BATCH = "it-related-batch-";

    private static final String BASE_ID = "990101";
    /** 共享 2 个标签，评分 6.0。 */
    private static final String NEAR_ID = "990102";
    /** 共享 1 个标签，评分 9.0——旧口径下它排第一。 */
    private static final String FAR_ID = "990103";

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
                item(BASE_ID, "排序基准", List.of("排序甲", "排序乙", "排序丙"), 8),
                item(NEAR_ID, "近邻作品", List.of("排序甲", "排序乙", "排序丁"), 6),
                item(FAR_ID, "远邻作品", List.of("排序甲", "排序戊", "排序己"), 9))));
    }

    @AfterEach
    void cleanUp() {
        jdbc.update("DELETE FROM work_tag WHERE work_ref IN (SELECT id FROM work WHERE source = ?)", SOURCE);
        jdbc.update("DELETE FROM work WHERE source = ?", SOURCE);
        jdbc.update("DELETE FROM import_batch_run WHERE batch_id LIKE ?", BATCH + "%");
        jdbc.update("DELETE FROM import_batch WHERE batch_id LIKE ?", BATCH + "%");
    }

    @Test
    @DisplayName("共享标签多的排前面，哪怕它的评分更低")
    void moreSharedTagsWinsOverHigherRating() {
        String baseWorkId = workRepository.findBySourceKey(SOURCE, BASE_ID).orElseThrow().workId();

        var related = workService.related(baseWorkId, 10);

        assertThat(related.items()).extracting(i -> i.title())
                .as("共享 2 个标签的 6 分作品要排在共享 1 个标签的 9 分作品前面")
                .containsSubsequence("近邻作品", "远邻作品");
    }

    @Test
    @DisplayName("和基准共享 0 个标签的作品不出现（召回仍然只看标签交集）")
    void unrelatedWorkIsNotRecalled() {
        jdbc.update("UPDATE work SET tags = CAST(? AS JSON) WHERE source = ? AND source_id = ?",
                "[\"孤立标签\"]", SOURCE, FAR_ID);
        jdbc.update("DELETE FROM work_tag WHERE work_ref = (SELECT id FROM work WHERE source = ? AND source_id = ?)",
                SOURCE, FAR_ID);
        String baseWorkId = workRepository.findBySourceKey(SOURCE, BASE_ID).orElseThrow().workId();

        var related = workService.related(baseWorkId, 10);

        assertThat(related.items()).extracting(i -> i.title()).doesNotContain("远邻作品");
    }

    static ImportItem item(String sourceId, String title, List<String> tags, int rating) {
        return new ImportItem(sourceId, "anime", title, null, null, 2020, tags,
                new SourceRating(BigDecimal.valueOf(rating), "0-10", "it"), null, null, List.of(),
                null, null, null, null, null);
    }
}
