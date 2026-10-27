package com.otaku.work;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.importer.ImportService;
import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchRequest.ImportItem;
import com.otaku.importer.dto.ImportBatchRequest.SourceRating;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/**
 * 标签词表（{@code GET /api/tags}）与多标签筛选（{@code tags=}，Issue #208）。
 *
 * <p>为什么走 MockMvc + 真 MySQL：这里验的是 SQL 的集合语义（{@code IN} + {@code GROUP BY ...
 * HAVING COUNT(DISTINCT tag)}）与参数解析的组合，Mock 掉仓储就只剩"我把参数传对了"。
 * 数据用导入链路写入——与线上同一套 {@code work_tag} 维护逻辑，避免手工 INSERT 与实现漂移。
 *
 * <p>没有 {@code IT_DB_PORT} 时整类跳过；CI 注入 3306 真跑。
 */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class TagEndpointsIntegrationTest {

    private static final String ID_PREFIX = "it8tag-";
    private static final String BATCH_PREFIX = "it8tag-batch-";
    /** 用带前缀的标签名，避免与库里其它数据串味（词表是全局的）。 */
    private static final String T1 = "it8-科幻";
    private static final String T2 = "it8-机战";
    private static final String T3 = "it8-日常";

    @Autowired
    private MockMvc mvc;

    @Autowired
    private ImportService importService;

    @Autowired
    private JdbcTemplate jdbc;

    @Autowired
    private ObjectMapper objectMapper;

    @AfterEach
    void cleanUp() {
        jdbc.update("DELETE FROM work_tag WHERE work_ref IN"
                + " (SELECT id FROM work WHERE source_id LIKE ?)", ID_PREFIX + "%");
        jdbc.update("DELETE FROM import_batch_run WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM import_batch WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM work WHERE source_id LIKE ?", ID_PREFIX + "%");
    }

    @Test
    @DisplayName("词表：带计数、按 count 降序/同名升序，total 是返回条数而不是词表总数")
    void tagVocabulary() throws Exception {
        seed();

        JsonNode body = okJson("/api/tags");

        assertThat(body.get("type").isNull()).as("不传 type 时回显 null").isTrue();
        assertThat(body.get("total").asInt()).isEqualTo(body.get("items").size());

        JsonNode items = body.get("items");
        // 全局不变式：按 count 降序，同分按 name 升序
        for (int i = 1; i < items.size(); i++) {
            int prev = items.get(i - 1).get("count").asInt();
            int cur = items.get(i).get("count").asInt();
            assertThat(prev).isGreaterThanOrEqualTo(cur);
            if (prev == cur) {
                assertThat(items.get(i - 1).get("name").asText())
                        .isLessThanOrEqualTo(items.get(i).get("name").asText());
            }
        }
        assertThat(countOf(items, T1)).isEqualTo(3);
        assertThat(countOf(items, T2)).isEqualTo(3);
        assertThat(countOf(items, T3)).isEqualTo(1);
    }

    @Test
    @DisplayName("词表按 type 过滤；limit 截断且 total 跟着变；非法 type 400")
    void tagVocabularyFilters() throws Exception {
        seed();

        JsonNode anime = okJson("/api/tags?type=anime");
        assertThat(anime.get("type").asText()).isEqualTo("anime");
        assertThat(countOf(anime.get("items"), T1)).isEqualTo(2);
        assertThat(countOf(anime.get("items"), T3)).as("comic 独有的标签不该出现在 anime 里").isZero();

        JsonNode limited = okJson("/api/tags?limit=1");
        assertThat(limited.get("items")).hasSize(1);
        assertThat(limited.get("total").asInt()).isEqualTo(1);

        MvcResult bad = mvc.perform(get("/api/tags?type=movie")).andReturn();
        assertThat(bad.getResponse().getStatus()).isEqualTo(400);
        assertThat(errorCode(bad)).isEqualTo("BAD_REQUEST");
    }

    @Test
    @DisplayName("多标签是 AND：两个标签都必须命中；单个标签与旧 tag= 等价")
    void multiTagIsAnd() throws Exception {
        seed();

        JsonNode both = okJson("/api/works", "tags", T1 + "," + T2);
        assertThat(both.get("total").asInt()).isEqualTo(2);
        assertThat(workIds(both)).contains(workIdOf("it8tag-1"), workIdOf("it8tag-3"))
                .doesNotContain(workIdOf("it8tag-2"), workIdOf("it8tag-4"));

        JsonNode onlyT3 = okJson("/api/works", "tags", T3);
        assertThat(onlyT3.get("total").asInt()).isEqualTo(1);
        assertThat(workIds(onlyT3)).containsExactly(workIdOf("it8tag-3"));

        // 单标签：tags 一个值 与 旧 tag= 结果一致
        assertThat(okJson("/api/works", "tags", T1).get("total").asInt())
                .isEqualTo(okJson("/api/works", "tag", T1).get("total").asInt());
    }

    @Test
    @DisplayName("AND 的分页与排序：总数正确、按评分降序、翻页不重不漏")
    void multiTagPagingAndSort() throws Exception {
        seed();

        JsonNode page1 = okJson("/api/works", "tags", T1 + "," + T2,
                "sort", "rating", "page_size", "1");
        assertThat(page1.get("total").asInt()).isEqualTo(2);
        assertThat(page1.get("items")).hasSize(1);
        assertThat(page1.get("items").get(0).get("work_id").asText()).isEqualTo(workIdOf("it8tag-3"));

        JsonNode page2 = okJson("/api/works", "tags", T1 + "," + T2,
                "sort", "rating", "page_size", "1", "page", "2");
        assertThat(page2.get("items")).hasSize(1);
        assertThat(page2.get("items").get(0).get("work_id").asText()).isEqualTo(workIdOf("it8tag-1"));

        // 无评分作品（it8tag-4）没有 T1，本来就不在结果里；这里确认总数与明细一致
        assertThat(page1.get("total").asInt()).isEqualTo(2);
    }

    @Test
    @DisplayName("参数边界：tag 与 tags 同时出现 400；超过 10 个标签 400；未知标签 200 空")
    void parameterGuards() throws Exception {
        seed();

        MvcResult conflict = mvc.perform(get("/api/works")
                        .param("tag", T1).param("tags", T2))
                .andReturn();
        assertThat(conflict.getResponse().getStatus()).isEqualTo(400);
        assertThat(errorCode(conflict)).isEqualTo("BAD_REQUEST");
        assertThat(conflict.getResponse().getContentAsString(StandardCharsets.UTF_8))
                .contains("不能同时使用");

        MvcResult tooMany = mvc.perform(get("/api/works").param("tags", elevenTags())).andReturn();
        assertThat(tooMany.getResponse().getStatus()).isEqualTo(400);

        JsonNode unknown = okJson("/api/works", "tags", T1 + ",it8-不存在");
        assertThat(unknown.get("total").asInt()).isZero();
        assertThat(unknown.get("items")).isEmpty();
    }

    @Test
    @DisplayName("多标签 + 年份：两个条件同时生效（AND 与等值过滤不能互相吞掉）")
    void multiTagWithYear() throws Exception {
        seed();
        importService.importBatch(new ImportBatchRequest(
                BATCH_PREFIX + UUID.randomUUID(), "otaku_site", null, List.of(
                itemWithYear("it8tag-5", "anime", "2021 样本", List.of(T1, T2), "8.5", 2021))));

        JsonNode y2022 = okJson("/api/works", "tags", T1 + "," + T2, "year", "2022");
        assertThat(y2022.get("total").asInt()).isEqualTo(2);

        JsonNode y2021 = okJson("/api/works", "tags", T1 + "," + T2, "year", "2021");
        assertThat(y2021.get("total").asInt()).isEqualTo(1);
        assertThat(workIds(y2021)).containsExactly(workIdOf("it8tag-5"));

        // 年份把结果筛空时仍是 200 + 空数组，不是 404
        assertThat(okJson("/api/works", "tags", T1 + "," + T2, "year", "1999").get("total").asInt())
                .isZero();
    }

    // ---------------------------------------------------------------- fixtures

    /**
     * 四条作品：
     * <pre>
     *   1 anime  T1,T2  8.0
     *   2 anime  T1     7.0
     *   3 comic  T1,T2,T3  9.0
     *   4 anime  T2     无评分
     * </pre>
     */
    private void seed() {
        importService.importBatch(new ImportBatchRequest(
                BATCH_PREFIX + UUID.randomUUID(), "otaku_site", null, List.of(
                item("it8tag-1", "anime", "AND 样本一", List.of(T1, T2), "8.0"),
                item("it8tag-2", "anime", "AND 样本二", List.of(T1), "7.0"),
                item("it8tag-3", "comic", "AND 样本三", List.of(T1, T2, T3), "9.0"),
                item("it8tag-4", "anime", "AND 样本四", List.of(T2), null))));
    }

    private static ImportItem item(String sourceId, String type, String title,
                                   List<String> tags, String rating) {
        return itemWithYear(sourceId, type, title, tags, rating, 2022);
    }

    private static ImportItem itemWithYear(String sourceId, String type, String title,
                                           List<String> tags, String rating, int year) {
        return new ImportItem(sourceId, type, title, null, null, year, tags,
                rating == null ? null : new SourceRating(new BigDecimal(rating), "0-10", "otaku_site"),
                null);
    }

    private JsonNode okJson(String path, String... params) throws Exception {
        var request = get(path);
        for (int i = 0; i + 1 < params.length; i += 2) {
            request.param(params[i], params[i + 1]);
        }
        MvcResult result = mvc.perform(request).andReturn();
        assertThat(result.getResponse().getStatus())
                .as("期望 200，实际 %s：%s", result.getResponse().getStatus(),
                        result.getResponse().getContentAsString(StandardCharsets.UTF_8))
                .isEqualTo(200);
        return objectMapper.readTree(result.getResponse().getContentAsString(StandardCharsets.UTF_8));
    }

    private static String errorCode(MvcResult result) throws Exception {
        return new ObjectMapper().readTree(
                        result.getResponse().getContentAsString(StandardCharsets.UTF_8))
                .get("error").get("code").asText();
    }

    private static int countOf(JsonNode items, String name) {
        for (JsonNode item : items) {
            if (name.equals(item.get("name").asText())) {
                return item.get("count").asInt();
            }
        }
        return 0;
    }

    private static List<String> workIds(JsonNode body) {
        List<String> ids = new ArrayList<>();
        body.get("items").forEach(item -> ids.add(item.get("work_id").asText()));
        return ids;
    }

    private String workIdOf(String sourceId) {
        return jdbc.queryForObject("SELECT work_id FROM work WHERE source_id = ?", String.class, sourceId);
    }

    private static String elevenTags() {
        StringBuilder sb = new StringBuilder();
        for (int i = 1; i <= 11; i++) {
            if (i > 1) {
                sb.append(',');
            }
            sb.append("t").append(i);
        }
        return sb.toString();
    }
}
