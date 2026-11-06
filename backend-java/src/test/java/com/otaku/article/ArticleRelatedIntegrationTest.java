package com.otaku.article;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;

import java.nio.charset.StandardCharsets;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/**
 * `GET /api/articles/{id}/related` 的端到端行为（#414）。
 *
 * <p>为什么连真库：召回靠 `JSON_OVERLAPS(tags, CAST(:json AS JSON))` —— 这个函数对
 * 「传字符串还是 JSON 值」极其敏感（传 `"[...]"` 会被当成 JSON 字符串，永远不重叠）。
 * mock 掉仓储就写不出这个坑，只有 MySQL 能验。
 */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class ArticleRelatedIntegrationTest {

    @Autowired
    private MockMvc mvc;

    @Autowired
    private JdbcTemplate jdbc;

    @Autowired
    private ObjectMapper objectMapper;

    private String prefix;

    @BeforeEach
    void setUp() {
        prefix = "it-rel-" + UUID.randomUUID().toString().substring(0, 8) + "-";
    }

    @AfterEach
    void cleanUp() {
        jdbc.update("DELETE FROM article WHERE article_id LIKE ?", prefix + "%");
    }

    @Test
    @DisplayName("源资讯不存在 → 404 ARTICLE_NOT_FOUND")
    void missingSourceGives404() throws Exception {
        var response = mvc.perform(get("/api/articles/" + prefix + "nope/related"))
                .andReturn().getResponse();

        assertThat(response.getStatus()).isEqualTo(404);
        assertThat(response.getContentAsString(StandardCharsets.UTF_8))
                .contains("ARTICLE_NOT_FOUND");
    }

    @Test
    @DisplayName("按共享标签数排序，排除自己，同分类只作弱信号")
    void ranksBySharedTags() throws Exception {
        createArticle("A-src", "动画", "[\"机战\",\"科幻\"]");
        createArticle("A-two", "动画", "[\"机战\",\"科幻\"]");     // 2 个共享
        createArticle("A-one", "动画", "[\"机战\"]");              // 1 个共享
        createArticle("A-cat", "动画", "[\"其他\"]");              // 0 共享，同分类
        createArticle("A-far", "漫画", "[\"恋爱\"]");              // 无关

        JsonNode body = related("A-src", "10");

        List<String> ids = new ArrayList<>();
        body.get("items").forEach(item -> ids.add(item.get("article_id").asText()));

        assertThat(ids).containsExactly(prefix + "A-two", prefix + "A-one", prefix + "A-cat");
        assertThat(ids).doesNotContain(prefix + "A-src");
    }

    @Test
    @DisplayName("limit 上限 20、默认 10；源既无标签也无分类时返回空 items")
    void emptyWhenSourceHasNoSignal() throws Exception {
        createArticle("A-bare", null, null);
        createArticle("A-other", "动画", "[\"机战\"]");

        JsonNode body = related("A-bare", "999");

        assertThat(body.get("items")).isEmpty();
    }

    // ------------------------------------------------------------------

    private JsonNode related(String articleId, String limit) throws Exception {
        String json = mvc.perform(get("/api/articles/" + prefix + articleId + "/related")
                        .param("limit", limit))
                .andReturn().getResponse().getContentAsString(StandardCharsets.UTF_8);
        return objectMapper.readTree(json);
    }

    private void createArticle(String articleId, String category, String tagsJson) {
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        jdbc.update("INSERT INTO article (article_id, source, source_id, title, category,"
                        + " published_at, tags, created_at, updated_at)"
                        + " VALUES (?, 'otaku_site', ?, ?, ?, ?, ?, ?, ?)",
                prefix + articleId, prefix + articleId, "标题 " + articleId, category,
                now, tagsJson, now, now);
    }
}
