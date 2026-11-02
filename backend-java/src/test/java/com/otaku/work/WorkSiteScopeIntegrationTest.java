package com.otaku.work;

import com.otaku.common.ApiException;
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
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * 「只显示首站收录的作品」（#370）在真库上的行为。
 *
 * <p>为什么必须连真库：这段逻辑全在 SQL 里——白名单 join、冗余列的写入期同步、
 * 四个查询面的过滤条件。Mock 掉仓储等于只测了 Java 的 if，证明不了
 * 「未收录的作品真的查不出来」。
 *
 * <p>开关只在这个类里打开（{@code properties}）：别的集成测试共用一个库，
 * 没有 site_scope 清单，开着会让它们凭空变空。
 *
 * <p>所有断言都用「自己的数据 + 基线差值」而不是绝对总数：所有用例共用一个库，
 * 别的类留下的作品（尤其 {@code otaku_site}，它永远 listed）会把绝对数顶歪。
 */
@SpringBootTest(properties = {
        "app.work.site-scope.enabled=true",
        // 自站来源用配置传，不在代码里写死站名（site-isolation 检查会拦）
        "app.work.site-scope.self-sources=" + WorkSiteScopeIntegrationTest.SELF_SOURCE})
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class WorkSiteScopeIntegrationTest {

    private static final String SOURCE = "it-scope-src";
    /** 配置成「自站来源」的那个 source：不走清单。 */
    static final String SELF_SOURCE = "it-scope-self";
    private static final String BATCH_PREFIX = "it-scope-batch-";
    private static final String TITLE_PREFIX = "范围测试-";
    private static final String TAG_COMMON = "范围测试标签";
    private static final String TAG_ONLY_UNLISTED = "范围外独有标签";

    /** 在首站收录清单里的两条。 */
    private static final String LISTED_1 = "990001";
    private static final String LISTED_2 = "990002";
    /** 不在清单里的那条。 */
    private static final String UNLISTED = "990003";

    @Autowired
    private ImportService importService;

    @Autowired
    private WorkService workService;

    @Autowired
    private WorkRepository workRepository;

    @Autowired
    private TagRepository tagRepository;

    @Autowired
    private JdbcTemplate jdbc;

    /** 导入前库里的可见总数：别的测试类留下的数据都算在基线里。 */
    private long baseline;

    @BeforeEach
    void setUp() {
        cleanUp();
        baseline = workService.list(null, null, null, null, null, 1, 1).total();

        // 清单先落库，再导入——写入路径按它判 site_listed。
        jdbc.update("INSERT IGNORE INTO site_scope (subject_id) VALUES (?), (?)",
                Long.parseLong(LISTED_1), Long.parseLong(LISTED_2));

        importService.importBatch(new ImportBatchRequest(BATCH_PREFIX + "1", SOURCE, null, List.of(
                item(LISTED_1, TITLE_PREFIX + "收录一", List.of(TAG_COMMON, "范围测试机战"), 9),
                item(LISTED_2, TITLE_PREFIX + "收录二", List.of(TAG_COMMON), 8),
                item(UNLISTED, TITLE_PREFIX + "未收录", List.of(TAG_COMMON, TAG_ONLY_UNLISTED), 10))));
    }

    @AfterEach
    void cleanUp() {
        jdbc.update("DELETE FROM work_tag WHERE work_ref IN (SELECT id FROM work WHERE source = ?)", SOURCE);
        jdbc.update("DELETE FROM work WHERE source = ?", SOURCE);
        jdbc.update("DELETE FROM import_batch_run WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM import_batch WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM site_scope WHERE subject_id IN (?, ?, ?)",
                Long.parseLong(LISTED_1), Long.parseLong(LISTED_2), Long.parseLong(UNLISTED));
    }

    private static ImportItem item(String sourceId, String title, List<String> tags, int rating) {
        return new ImportItem(sourceId, "anime", title, null, null, 2020, tags,
                new SourceRating(BigDecimal.valueOf(rating), "0-10", "it"), null, null, List.of(),
                null, null, null, null, null);
    }

    private List<String> myTitles(int pageSize) {
        return workService.list(null, null, null, null, null, 1, pageSize).items().stream()
                .map(i -> i.title())
                .filter(t -> t.startsWith(TITLE_PREFIX))
                .toList();
    }

    @Test
    @DisplayName("列表与计数只含收录内的：3 部导进来，只查出 2 部")
    void listOnlyReturnsListed() {
        var page = workService.list(null, null, null, null, null, 1, 50);

        assertThat(myTitles(50))
                .containsExactlyInAnyOrder(TITLE_PREFIX + "收录一", TITLE_PREFIX + "收录二");
        assertThat(page.total()).as("计数与列表必须同一口径").isEqualTo(baseline + 2);
    }

    @Test
    @DisplayName("未收录的详情按「不存在」处理：404 而不是 403")
    void detailOfUnlistedIsNotFound() {
        WorkRecord unlisted = workRepository.findBySourceKey(SOURCE, UNLISTED).orElseThrow();
        assertThatThrownBy(() -> workService.detail(unlisted.workId()))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("不存在");
    }

    @Test
    @DisplayName("标签词表不给未收录作品计数：独有标签不出现，共有标签只算收录的两部")
    void tagVocabularyIgnoresUnlisted() {
        var tags = tagRepository.top(null, 500);

        assertThat(tags).extracting(t -> t.name())
                .as("只在未收录作品上出现的标签不该进词表")
                .doesNotContain(TAG_ONLY_UNLISTED);
        assertThat(tags).filteredOn(t -> TAG_COMMON.equals(t.name()))
                .singleElement()
                .extracting(t -> t.count())
                .as("共有标签：三部的标签，只数收录的两部")
                .isEqualTo(2L);
    }

    @Test
    @DisplayName("相关推荐不推未收录作品（详情 404、推荐却推得出来最说不清）")
    void relatedExcludesUnlisted() {
        WorkRecord listed = workRepository.findBySourceKey(SOURCE, LISTED_1).orElseThrow();

        var related = workService.related(listed.workId(), 18);

        assertThat(related.items()).extracting(i -> i.title())
                .doesNotContain(TITLE_PREFIX + "未收录");
    }

    @Test
    @DisplayName("清单变了，重新导入就跟着变：补进清单后同一条变可见")
    void reimportReevaluatesAgainstScope() {
        jdbc.update("INSERT IGNORE INTO site_scope (subject_id) VALUES (?)", Long.parseLong(UNLISTED));

        // 再导一次同一条（内容不变也会走 updateContent，重算标记）
        importService.importBatch(new ImportBatchRequest(BATCH_PREFIX + "2", SOURCE, null,
                List.of(item(UNLISTED, TITLE_PREFIX + "未收录", List.of(TAG_COMMON), 10))));

        Integer listed = jdbc.queryForObject(
                "SELECT site_listed FROM work WHERE source = ? AND source_id = ?",
                Integer.class, SOURCE, UNLISTED);
        assertThat(listed).as("清单补进来后应立刻变 1").isEqualTo(1);
        assertThat(workService.list(null, null, null, null, null, 1, 1).total())
                .isEqualTo(baseline + 3);
    }

    @Test
    @DisplayName("自站来源不走清单：配置里的 source 写入时直接标 1")
    void selfSourceIsAlwaysListed() {
        importService.importBatch(new ImportBatchRequest(BATCH_PREFIX + "3", SELF_SOURCE, null,
                List.of(item("777777", "自站作品", List.of("自站标签"), 7))));

        Integer listed = jdbc.queryForObject(
                "SELECT site_listed FROM work WHERE source = ? AND source_id = '777777'",
                Integer.class, SELF_SOURCE);
        assertThat(listed).as("配置在 self-sources 里的来源，不该再看清单").isEqualTo(1);

        jdbc.update("DELETE FROM work_tag WHERE work_ref IN"
                + " (SELECT id FROM work WHERE source = ? AND source_id = '777777')", SELF_SOURCE);
        jdbc.update("DELETE FROM work WHERE source = ? AND source_id = '777777'", SELF_SOURCE);
    }
}
