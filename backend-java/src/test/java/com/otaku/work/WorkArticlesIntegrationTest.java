package com.otaku.work;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.appconfig.AppConfigService;
import com.otaku.article.ArticleImportService;
import com.otaku.article.ArticleRelatedIdsSemantics;
import com.otaku.article.dto.ArticleDtos.ArticlePage;
import com.otaku.article.dto.ArticleImportRequest;
import com.otaku.article.dto.ArticleImportRequest.ArticleImportItem;
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
import java.time.OffsetDateTime;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 作品→资讯（#409）在真库上的行为。
 *
 * <p>为什么必须连真库：这一条全靠 {@code JSON_CONTAINS} 的语义——JSON 数组里
 * {@code "11972"}（字符串）与 {@code 11972}（数字）**不相等**，写成一种就有一半数据
 * 静默查不到；再加上「按 subject id 匹配」本身建立在两套号不混用的前提上。
 * Mock 掉仓储等于把这些全绕开，什么都验不到。
 *
 * <p>三种存法都要覆盖：字符串（Java 导入声明 {@code List<String>}）、数字
 * （数据侧从 SQLite 读出的 {@code bangumi_id}），以及**不该命中的**：
 * 另一部作品、以及语义没切时整条路径关闭。
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class WorkArticlesIntegrationTest {

    /** 资讯来源用独立值，跑完按它整批删，不碰别的用例的数据。 */
    private static final String ARTICLE_SOURCE = "it-work-articles";
    private static final String WORK_SOURCE = "bangumi";
    private static final String SUBJECT_WITH_ARTICLES = "9711972";
    private static final String SUBJECT_WITHOUT_ARTICLES = "9788999";

    @Autowired
    private ImportService importService;

    @Autowired
    private ArticleImportService articleImportService;

    @Autowired
    private WorkService workService;

    @Autowired
    private WorkRepository workRepository;

    @Autowired
    private AppConfigService configService;

    @Autowired
    private JdbcTemplate jdbc;

    private String workWithArticles;
    private String workWithoutArticles;

    @BeforeEach
    void setUp() {
        cleanUp();
        importService.importBatch(new ImportBatchRequest("it-work-articles-w1", WORK_SOURCE, null, List.of(
                new ImportItem(SUBJECT_WITH_ARTICLES, "anime", "带资讯的作品", null, null, 2020,
                        List.of("关联测试标签"), new SourceRating(BigDecimal.valueOf(8), "0-10", "it"),
                        null, null, List.of(), null, null, null, null, null))));
        importService.importBatch(new ImportBatchRequest("it-work-articles-w2", WORK_SOURCE, null, List.of(
                new ImportItem(SUBJECT_WITHOUT_ARTICLES, "anime", "没有资讯的作品", null, null, 2021,
                        List.of("关联测试标签"), new SourceRating(BigDecimal.valueOf(7), "0-10", "it"),
                        null, null, List.of(), null, null, null, null, null))));

        workWithArticles = workRepository.findBySourceKey(WORK_SOURCE, SUBJECT_WITH_ARTICLES).orElseThrow().workId();
        workWithoutArticles = workRepository.findBySourceKey(WORK_SOURCE, SUBJECT_WITHOUT_ARTICLES).orElseThrow().workId();

        articleImportService.importArticles(new ArticleImportRequest(
                "it-work-articles-a1", ARTICLE_SOURCE, OffsetDateTime.parse("2026-11-01T00:00:00Z"),
                List.of(
                        // 字符串数组：Java 导入默认形状
                        article("9101", "关联资讯（字符串）", "2026-10-01T08:00:00Z",
                                List.of(SUBJECT_WITH_ARTICLES)),
                        // 数字数组：数据侧从 SQLite 读出来的 bangumi_id 是整数。
                        // 导入接口声明的是 List<String>，表达不了数字，所以先按字符串导入、
                        // 再直接把列改成数字数组——这正是「绕过 Java 归一直接写库」的样子。
                        article("9102", "关联资讯（数字）", "2026-10-03T08:00:00Z",
                                List.of(SUBJECT_WITH_ARTICLES)),
                        // 关联到一部我们没导入的 subject（悬空号）：反查时不该出现在任何作品下
                        article("9103", "别人的资讯", "2026-10-02T08:00:00Z",
                                List.of("9799999")),
                        // 没有关联作品：不该出现
                        article("9104", "无关联资讯", "2026-10-04T08:00:00Z", List.of()))));

        // 把 9102 的关联作品改成**数字数组**（见上面那段注释）
        jdbc.update("UPDATE article SET related_work_ids = CAST(? AS JSON) WHERE source = ? AND source_id = ?",
                "[" + SUBJECT_WITH_ARTICLES + "]", ARTICLE_SOURCE, "9102");

        enableSemantics(ArticleRelatedIdsSemantics.SUBJECT_ID);
    }

    @AfterEach
    void cleanUp() {
        jdbc.update("DELETE FROM article WHERE source = ?", ARTICLE_SOURCE);
        jdbc.update("DELETE FROM work_tag WHERE work_ref IN (SELECT id FROM work WHERE source = ?)", WORK_SOURCE);
        jdbc.update("DELETE FROM work WHERE source = ? AND source_id IN (?, ?)",
                WORK_SOURCE, SUBJECT_WITH_ARTICLES, SUBJECT_WITHOUT_ARTICLES);
        jdbc.update("DELETE FROM app_config WHERE config_key = ?", ArticleRelatedIdsSemantics.KEY);
        configService.reload();
    }

    @Test
    @DisplayName("字符串与数字两种存法都反查得到，按发布时间倒序，别人的资讯不混进来")
    void findsArticlesInBothJsonForms() {
        ArticlePage page = workService.relatedArticles(workWithArticles, 1, 20);

        assertThat(page.total()).isEqualTo(2);
        assertThat(page.items()).extracting("articleId").hasSize(2)
                .allSatisfy(id -> assertThat(id).isNotNull());
        // 数字那条（10-03）比字符串那条（10-01）新，排前面
        assertThat(page.items()).extracting("title")
                .containsExactly("关联资讯（数字）", "关联资讯（字符串）");
        assertThat(page.items()).extracting("title").doesNotContain("别人的资讯", "无关联资讯");
    }

    @Test
    @DisplayName("没被关联过的作品返回空页，不是 404")
    void returnsEmptyForWorkWithoutArticles() {
        ArticlePage page = workService.relatedArticles(workWithoutArticles, 1, 20);

        assertThat(page.total()).isZero();
        assertThat(page.items()).isEmpty();
        assertThat(page.totalPages()).isZero();
    }

    @Test
    @DisplayName("分页：total 是全部匹配数，items 只给本页")
    void paginates() {
        ArticlePage first = workService.relatedArticles(workWithArticles, 1, 1);

        assertThat(first.total()).isEqualTo(2);
        assertThat(first.totalPages()).isEqualTo(2);
        assertThat(first.items()).hasSize(1);
        assertThat(first.items().get(0).title()).isEqualTo("关联资讯（数字）");

        ArticlePage second = workService.relatedArticles(workWithArticles, 2, 1);
        assertThat(second.items()).hasSize(1);
        assertThat(second.items().get(0).title()).isEqualTo("关联资讯（字符串）");
    }

    @Test
    @DisplayName("语义开关没切（默认 content_id）：一条都不查，返回空——宁可空也不要撞号")
    void returnsEmptyBeforeSemanticsSwitched() {
        enableSemantics(ArticleRelatedIdsSemantics.CONTENT_ID);

        ArticlePage page = workService.relatedArticles(workWithArticles, 1, 20);

        assertThat(page.total()).isZero();
        assertThat(page.items()).isEmpty();
    }

    /** 运行期开关走 app_config（与运维用 /internal/app/config 改的是同一个键）。 */
    private void enableSemantics(String value) {
        configService.put(ArticleRelatedIdsSemantics.KEY,
                new ObjectMapper().getNodeFactory().textNode(value), "it");
    }

    private static ArticleImportItem article(String sourceId, String title, String publishedAt,
                                             List<String> relatedWorkIds) {
        return new ArticleImportItem(sourceId, title, null, "正文", "动画",
                OffsetDateTime.parse(publishedAt), "首站", null, null, List.of(), relatedWorkIds);
    }
}
