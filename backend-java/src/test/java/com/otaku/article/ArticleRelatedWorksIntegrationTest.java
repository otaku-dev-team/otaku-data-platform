package com.otaku.article;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.appconfig.AppConfigService;
import com.otaku.article.dto.ArticleDtos.ArticleDetail;
import com.otaku.article.dto.ArticleImportRequest;
import com.otaku.article.dto.ArticleImportRequest.ArticleImportItem;
import com.otaku.importer.ImportService;
import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchRequest.ImportItem;
import com.otaku.importer.dto.ImportBatchRequest.SourceRating;
import com.otaku.work.dto.WorkSummaryDto;
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
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 资讯详情的「关联作品」解析（#408 资讯→作品）在真库上的行为。
 *
 * <p>必须连真库的原因：这条链上有三道过滤写在 SQL 里——下架、成人、收录范围，
 * 还有一次 `IN` 的批查。Mock 掉仓储就只能验证「我调了那个方法」，验不出过滤是否真的生效。
 *
 * <p>顺序也是断言项：来源站编辑排的位次是内容的一部分，按 id 或按库返回顺序重排都算错。
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class ArticleRelatedWorksIntegrationTest {

    private static final String ARTICLE_SOURCE = "it-article-works";
    private static final String WORK_SOURCE = "bangumi";
    private static final String SUBJECT_A = "9700001";
    private static final String SUBJECT_B = "9700002";
    private static final String SUBJECT_GONE = "9700003";
    private static final String SUBJECT_UNKNOWN = "9799999";

    @Autowired
    private ImportService importService;

    @Autowired
    private ArticleImportService articleImportService;

    @Autowired
    private ArticleDetailAssembler assembler;

    @Autowired
    private AppConfigService configService;

    @Autowired
    private JdbcTemplate jdbc;

    private String articleId;

    @BeforeEach
    void setUp() {
        cleanUp();
        importWorks();
        // 关联顺序刻意不是 id 顺序、也不是字母序：B → A → 已下架 → 不存在的号
        articleImportService.importArticles(new ArticleImportRequest(
                "it-article-works-b1", ARTICLE_SOURCE, OffsetDateTime.parse("2026-11-01T00:00:00Z"),
                List.of(new ArticleImportItem("9201", "带关联作品的资讯", null, "正文", "动画",
                        OffsetDateTime.parse("2026-10-01T08:00:00Z"), "首站", null, null,
                        List.of(), List.of(SUBJECT_B, SUBJECT_A, SUBJECT_GONE, SUBJECT_UNKNOWN)))));

        articleId = jdbc.queryForObject(
                "SELECT article_id FROM article WHERE source = ? AND source_id = ?",
                String.class, ARTICLE_SOURCE, "9201");

        // 第三部软删：关联作品是「一排卡片」，挂一部点进去只有「已下架」的作品没有意义
        jdbc.update("UPDATE work SET deleted_at = NOW() WHERE source = ? AND source_id = ?",
                WORK_SOURCE, SUBJECT_GONE);

        enableSemantics(ArticleRelatedIdsSemantics.SUBJECT_ID);
    }

    @AfterEach
    void cleanUp() {
        jdbc.update("DELETE FROM article WHERE source = ?", ARTICLE_SOURCE);
        jdbc.update("DELETE FROM work_tag WHERE work_ref IN (SELECT id FROM work WHERE source = ?)", WORK_SOURCE);
        jdbc.update("DELETE FROM work WHERE source = ? AND source_id IN (?, ?, ?)",
                WORK_SOURCE, SUBJECT_A, SUBJECT_B, SUBJECT_GONE);
        jdbc.update("DELETE FROM app_config WHERE config_key = ?", ArticleRelatedIdsSemantics.KEY);
        configService.reload();
    }

    @Test
    @DisplayName("按来源站原序返回，跳过已下架与查不到的号")
    void resolvesInOriginalOrderSkippingUnavailable() {
        ArticleDetail detail = assembler.detail(articleId);

        assertThat(detail.relatedWorkIds())
                .containsExactly(SUBJECT_B, SUBJECT_A, SUBJECT_GONE, SUBJECT_UNKNOWN);
        assertThat(detail.relatedWorks()).extracting(WorkSummaryDto::title)
                .containsExactly("作品 " + SUBJECT_B, "作品 " + SUBJECT_A);
    }

    @Test
    @DisplayName("解析出的卡片带本地 work_id 与封面口径，客户端可直接跳转")
    void resolvedSummaryCarriesLocalWorkId() {
        ArticleDetail detail = assembler.detail(articleId);

        assertThat(detail.relatedWorks()).isNotNull().isNotEmpty()
                .allSatisfy(work -> assertThat(work.workId()).startsWith("W-"));
    }

    @Test
    @DisplayName("语义没切：related_works 保持 null（未启用解析），不是 []")
    void nullBeforeSemanticsSwitched() {
        enableSemantics(ArticleRelatedIdsSemantics.CONTENT_ID);

        ArticleDetail detail = assembler.detail(articleId);

        assertThat(detail.relatedWorks()).isNull();
        assertThat(detail.relatedWorkIds()).hasSize(4);
    }

    private void importWorks() {
        importService.importBatch(new ImportBatchRequest("it-article-works-w1", WORK_SOURCE, null, List.of(
                workItem(SUBJECT_A), workItem(SUBJECT_B), workItem(SUBJECT_GONE))));
    }

    private static ImportItem workItem(String subjectId) {
        return new ImportItem(subjectId, "anime", "作品 " + subjectId, null, null, 2020,
                List.of("关联作品测试"), new SourceRating(BigDecimal.valueOf(8), "0-10", "it"),
                null, null, List.of(), null, null, null, null, null);
    }

    private void enableSemantics(String value) {
        configService.put(ArticleRelatedIdsSemantics.KEY,
                new ObjectMapper().getNodeFactory().textNode(value), "it");
    }
}
