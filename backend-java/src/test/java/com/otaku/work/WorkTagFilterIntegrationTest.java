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
 * 标签筛选的写入期一致性：导入之后 {@code work_tag} 必须与 {@code work.tags} 一致，
 * 否则「筛选出来的作品」和「作品自己身上的标签」会互相打架。
 *
 * <p>为什么必须连真库：这里验的是 {@code JSON_TABLE} 拆数组 + 自增主键回填 + 整组替换，
 * 全是 MySQL 方言；Mock 掉仓储等于只测了 Java 分支，H2 也不支持这段语法。
 *
 * <p>没有 {@code IT_DB_PORT} 时整类跳过（普通 {@code mvn test} 不需要数据库），
 * CI 由 workflow 注入 {@code IT_DB_PORT=3306} 真跑。
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class WorkTagFilterIntegrationTest {

    private static final String ID_PREFIX = "it-tag-";
    private static final String BATCH_PREFIX = "it-tag-batch-";

    @Autowired
    private ImportService importService;

    @Autowired
    private WorkService workService;

    @Autowired
    private JdbcTemplate jdbc;

    @AfterEach
    void cleanUp() {
        // work_tag 没有外键（work 行永不删除），必须显式先清，否则会留下悬空引用
        jdbc.update("DELETE FROM work_tag WHERE work_ref IN"
                + " (SELECT id FROM work WHERE source_id LIKE ?)", ID_PREFIX + "%");
        jdbc.update("DELETE FROM import_batch_run WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM import_batch WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM work WHERE source_id LIKE ?", ID_PREFIX + "%");
    }

    @Test
    @DisplayName("导入后标签表同步，按标签能查到，未知标签查不到")
    void importPopulatesTagIndex() {
        importBatch(item("it-tag-1", "魔法少女 1", List.of("科幻", "日常"), "8.5"));

        assertThat(tagOf("it-tag-1")).containsExactlyInAnyOrder("科幻", "日常");
        assertThat(workIdsByTag("科幻")).containsExactly(workIdOf("it-tag-1"));
        assertThat(workIdsByTag("这个标签不存在")).isEmpty();
    }

    @Test
    @DisplayName("改标签重导：旧标签不再命中，新标签命中（整组替换而非追加）")
    void reimportReplacesTags() {
        importBatch(item("it-tag-2", "换标签作品", List.of("科幻", "机战"), "7.0"));
        assertThat(tagRows("it-tag-2")).isEqualTo(2);

        importBatch(item("it-tag-2", "换标签作品", List.of("治愈"), "7.0"));

        assertThat(tagRows("it-tag-2")).as("旧标签必须被删掉，不能累积").isEqualTo(1);
        assertThat(tagOf("it-tag-2")).containsExactly("治愈");
    }

    @Test
    @DisplayName("来源不再提供标签（null）时保留原标签：三态语义不能因为加了索引表而改变")
    void nullTagsDoNotClearIndex() {
        importBatch(item("it-tag-3", "保留标签作品", List.of("悬疑"), "6.0"));

        importBatch(item("it-tag-3", "保留标签作品", null, "6.0"));

        assertThat(tagOf("it-tag-3")).containsExactly("悬疑");
    }

    @Test
    @DisplayName("评分变化会同步到标签表：标签内按评分排序依赖这个冗余列")
    void ratingChangePropagatesToTagIndex() {
        importBatch(item("it-tag-4", "评分变化作品", List.of("热血"), "6.0"));
        assertThat(tagRating("it-tag-4", "热血")).isEqualByComparingTo("6.00");

        importBatch(item("it-tag-4", "评分变化作品", List.of("热血"), "9.1"));

        assertThat(tagRating("it-tag-4", "热血")).isEqualByComparingTo("9.10");
    }

    @Test
    @DisplayName("按标签筛选：命中正确、可与类型组合、未知标签返回空而不是报错")
    void filterByTag() {
        importBatch(
                item("it-tag-5", "科幻动画", List.of("科幻"), "8.0"),
                item("it-tag-6", "科幻漫画", List.of("科幻"), "7.5"),
                item("it-tag-7", "纯日常动画", List.of("日常"), "7.0"));

        var scifi = workService.list(null, null, "科幻", null, null, 1, 50);
        assertThat(scifi.total()).isEqualTo(2);
        assertThat(scifi.items())
                .extracting(com.otaku.work.dto.WorkSummaryDto::workId)
                .doesNotContain(workIdOf("it-tag-7"));

        var scifiAnime = workService.list("anime", null, "科幻", null, null, 1, 50);
        assertThat(scifiAnime.total()).isEqualTo(2);

        var unknown = workService.list(null, null, "不存在的标签", null, null, 1, 50);
        assertThat(unknown.total()).isZero();
        assertThat(unknown.items()).isEmpty();
    }

    @Test
    @DisplayName("榜单下限：无评分作品被排除；标签内与全站两条查询路径都要生效")
    void minRatingExcludesUnrated() {
        importBatch(
                item("it-tag-8", "高分科幻", List.of("榜单样本"), "8.5"),
                item("it-tag-9", "低分科幻", List.of("榜单样本"), "5.0"),
                item("it-tag-10", "无分科幻", List.of("榜单样本"), null));

        // 全站路径（tag 为空，条件落在 work 表）：min_rating=0 的计数必须等于「有评分」的条数，
        // 这比对具体 ID 更稳——库里本来就有别的 anime，不该假设只有测试数据。
        Long ratedAnime = jdbc.queryForObject(
                "SELECT COUNT(*) FROM work WHERE work_type = 'anime' AND rating_value IS NOT NULL",
                Long.class);
        var allRated = workService.list("anime", null, null, "rating", "0", 1, 1);
        assertThat(allRated.total()).isEqualTo(ratedAnime);

        // 标签路径（条件落在 work_tag.rating_value 冗余列上）
        var tagged = workService.list(null, null, "榜单样本", "rating", "7", 1, 50);
        assertThat(tagged.total()).isEqualTo(1);
        assertThat(tagged.items())
                .extracting(com.otaku.work.dto.WorkSummaryDto::workId)
                .containsExactly(workIdOf("it-tag-8"));

        // 下限不影响「有评分」之外的语义：不过滤时三条都在
        assertThat(workService.list(null, null, "榜单样本", null, null, 1, 50).total()).isEqualTo(3);
    }

    // ---------------------------------------------------------------- helpers

    private void importBatch(ImportItem... items) {
        importService.importBatch(new ImportBatchRequest(
                BATCH_PREFIX + UUID.randomUUID(), "otaku_site", null, List.of(items)));
    }

    private static ImportItem item(String sourceId, String title, List<String> tags, String rating) {
        return new ImportItem(
                sourceId, "anime", title, null, null, 2022, tags,
                rating == null ? null : new SourceRating(new BigDecimal(rating), "0-10", "otaku_site"),
                null);
    }

    private int tagRows(String sourceId) {
        Integer n = jdbc.queryForObject(
                "SELECT COUNT(*) FROM work_tag WHERE work_ref = (SELECT id FROM work WHERE source_id = ?)",
                Integer.class, sourceId);
        return n == null ? 0 : n;
    }

    private List<String> tagOf(String sourceId) {
        return jdbc.queryForList(
                "SELECT tag FROM work_tag WHERE work_ref = (SELECT id FROM work WHERE source_id = ?)"
                        + " ORDER BY tag", String.class, sourceId);
    }

    private BigDecimal tagRating(String sourceId, String tag) {
        return jdbc.queryForObject(
                "SELECT rating_value FROM work_tag WHERE tag = ?"
                        + " AND work_ref = (SELECT id FROM work WHERE source_id = ?)",
                BigDecimal.class, tag, sourceId);
    }

    private String workIdOf(String sourceId) {
        return jdbc.queryForObject("SELECT work_id FROM work WHERE source_id = ?", String.class, sourceId);
    }

    private List<String> workIdsByTag(String tag) {
        return jdbc.queryForList(
                "SELECT w.work_id FROM work_tag t JOIN work w ON w.id = t.work_ref"
                        + " WHERE t.tag = ? AND w.source_id LIKE ?", String.class, tag, ID_PREFIX + "%");
    }
}
