package com.otaku.articlefavorite;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.common.SessionTokens;
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
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;

import java.nio.charset.StandardCharsets;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;

/**
 * `GET/PUT/DELETE /api/me/article-favorites` 的端到端行为（#377）。
 *
 * <p>为什么连真库：幂等 upsert 依赖 `uk_article_favorite_user_article` 唯一键 +
 * `ON DUPLICATE KEY UPDATE`；列表的排序与「计数和列表同一 JOIN 口径」也只有真
 * MySQL 能验。mock 仓储会把这两个最容易出错的点直接跳过。
 *
 * <p>为什么走 MockMvc：路径必须挂在 `/api/me/**` 下才会被 AuthFilter 拦。
 * 如果哪天有人改成 `/api/article-favorites`，第一条用例就该红，而不是静默
 * 变成匿名可读个人收藏。
 */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class ArticleFavoriteIntegrationTest {

    @Autowired
    private MockMvc mvc;

    @Autowired
    private JdbcTemplate jdbc;

    @Autowired
    private ObjectMapper objectMapper;

    private String prefix;
    private String tokenA;
    private String tokenB;
    private long userA;
    private long userB;

    @BeforeEach
    void setUp() {
        prefix = "it-af-" + UUID.randomUUID().toString().substring(0, 8) + "-";
        tokenA = SessionTokens.newToken();
        tokenB = SessionTokens.newToken();
        userA = createUser("a", tokenA);
        userB = createUser("b", tokenB);
    }

    @AfterEach
    void cleanUp() {
        jdbc.update("DELETE FROM article_favorite WHERE user_id IN (?, ?)", userA, userB);
        jdbc.update("DELETE FROM user_session WHERE user_id IN (?, ?)", userA, userB);
        jdbc.update("DELETE FROM app_user WHERE id IN (?, ?)", userA, userB);
        jdbc.update("DELETE FROM article WHERE article_id LIKE ?", prefix + "%");
    }

    @Test
    @DisplayName("没带令牌 → 401（路径必须在 /api/me/** 下）")
    void requiresAuthentication() throws Exception {
        int status = mvc.perform(get("/api/me/article-favorites"))
                .andReturn().getResponse().getStatus();
        assertThat(status).isEqualTo(401);
    }

    @Test
    @DisplayName("PUT 幂等：重复收藏只有一行，状态始终 favorited=true")
    void putIsIdempotent() throws Exception {
        String articleId = createArticle("A1", "动画", "[\"机战\"]");

        JsonNode first = body(authedPut("/api/me/article-favorites/" + articleId, tokenA), 200);
        JsonNode second = body(authedPut("/api/me/article-favorites/" + articleId, tokenA), 200);

        assertThat(first.get("favorited").asBoolean()).isTrue();
        assertThat(second.get("favorited").asBoolean()).isTrue();
        assertThat(second.get("article_id").asText()).isEqualTo(articleId);
        Integer rows = jdbc.queryForObject(
                "SELECT COUNT(*) FROM article_favorite WHERE user_id = ? AND article_id = ?",
                Integer.class, userA, articleId);
        assertThat(rows).isEqualTo(1);
    }

    @Test
    @DisplayName("DELETE 幂等：第一次 204，第二次仍 204；之后状态为未收藏")
    void deleteIsIdempotent() throws Exception {
        String articleId = createArticle("A2", "漫画", "[\"科幻\"]");
        body(authedPut("/api/me/article-favorites/" + articleId, tokenA), 200);

        assertThat(status(authedDelete("/api/me/article-favorites/" + articleId, tokenA)))
                .isEqualTo(204);
        assertThat(status(authedDelete("/api/me/article-favorites/" + articleId, tokenA)))
                .isEqualTo(204);

        JsonNode state = body(authedGet("/api/me/article-favorites/" + articleId, tokenA), 200);
        assertThat(state.get("favorited").asBoolean()).isFalse();
        assertThat(state.get("favorited_at").isNull()).isTrue();
    }

    @Test
    @DisplayName("资讯不存在 → 404 ARTICLE_NOT_FOUND；未收藏不是错误")
    void missingArticleGives404() throws Exception {
        var response = mvc.perform(authedPut("/api/me/article-favorites/" + prefix + "nope", tokenA))
                .andReturn().getResponse();
        assertThat(response.getStatus()).isEqualTo(404);
        assertThat(response.getContentAsString(StandardCharsets.UTF_8))
                .contains("ARTICLE_NOT_FOUND");

        String existing = createArticle("A3", "游戏", null);
        JsonNode state = body(authedGet("/api/me/article-favorites/" + existing, tokenB), 200);
        assertThat(state.get("favorited").asBoolean()).isFalse();
    }

    @Test
    @DisplayName("列表按收藏时间倒序、内嵌资讯摘要且不含正文；分页口径正确")
    void listOrdersAndPaginates() throws Exception {
        String a = createArticle("A4", "动画", "[\"机战\"]");
        String b = createArticle("A5", "漫画", "[\"科幻\"]");
        String c = createArticle("A6", "游戏", null);
        body(authedPut("/api/me/article-favorites/" + a, tokenA), 200);
        body(authedPut("/api/me/article-favorites/" + b, tokenA), 200);
        body(authedPut("/api/me/article-favorites/" + c, tokenA), 200);
        // 不依赖「PUT 之间的毫秒差」：直接写死三次收藏时间，排序断言才稳定。
        setFavoritedAt(a, "2026-11-01T10:00:00");
        setFavoritedAt(b, "2026-11-02T10:00:00");
        setFavoritedAt(c, "2026-11-03T10:00:00");

        JsonNode firstPage = body(authedGet("/api/me/article-favorites?page=1&page_size=2", tokenA), 200);
        assertThat(firstPage.get("total").asLong()).isEqualTo(3);
        assertThat(firstPage.get("total_pages").asInt()).isEqualTo(2);
        assertThat(firstPage.get("items")).hasSize(2);
        assertThat(firstPage.get("items").get(0).get("article").get("article_id").asText())
                .isEqualTo(c);
        assertThat(firstPage.get("items").get(0).get("article").has("body")).isFalse();
        assertThat(firstPage.get("items").get(0).get("article").get("title").asText())
                .isEqualTo("标题-A6");

        JsonNode secondPage = body(authedGet("/api/me/article-favorites?page=2&page_size=2", tokenA), 200);
        assertThat(secondPage.get("items")).hasSize(1);
        assertThat(secondPage.get("items").get(0).get("article").get("article_id").asText())
                .isEqualTo(a);
    }

    @Test
    @DisplayName("用户隔离：A 的收藏不出现在 B 的列表里")
    void userIsolation() throws Exception {
        String articleId = createArticle("A7", "动画", null);
        body(authedPut("/api/me/article-favorites/" + articleId, tokenA), 200);

        JsonNode listB = body(authedGet("/api/me/article-favorites", tokenB), 200);
        assertThat(listB.get("total").asLong()).isZero();
        assertThat(listB.get("items")).isEmpty();

        JsonNode stateB = body(authedGet("/api/me/article-favorites/" + articleId, tokenB), 200);
        assertThat(stateB.get("favorited").asBoolean()).isFalse();
    }

    private long createUser(String suffix, String token) {
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        jdbc.update("INSERT INTO app_user (user_id, username, password_hash, created_at, updated_at)"
                        + " VALUES (?, ?, ?, ?, ?)",
                prefix + suffix, prefix + suffix + "-name", "x", now, now);
        Long id = jdbc.queryForObject("SELECT id FROM app_user WHERE user_id = ?",
                Long.class, prefix + suffix);
        jdbc.update("INSERT INTO user_session (token_hash, user_id, created_at, expires_at)"
                        + " VALUES (?, ?, ?, ?)",
                SessionTokens.hash(token), id, now, now.plusDays(30));
        return id;
    }

    private String createArticle(String suffix, String category, String tagsJson) {
        String articleId = prefix + suffix;
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        jdbc.update("""
                        INSERT INTO article (article_id, source, source_id, title, summary, body,
                                             category, published_at, source_name, source_url,
                                             cover_url, tags, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                articleId, "it", articleId, "标题-" + suffix, "摘要-" + suffix, "正文不该出现在列表",
                category, now, "测试来源", "https://example.com/" + articleId,
                "https://example.com/cover.jpg", tagsJson, now, now);
        return articleId;
    }

    private void setFavoritedAt(String articleId, String timestamp) {
        LocalDateTime at = LocalDateTime.parse(timestamp);
        jdbc.update("UPDATE article_favorite SET created_at = ?, updated_at = ?"
                + " WHERE user_id = ? AND article_id = ?", at, at, userA, articleId);
    }

    private MockHttpServletRequestBuilder authedPut(String path, String token) {
        return put(path).header("Authorization", "Bearer " + token);
    }

    private MockHttpServletRequestBuilder authedDelete(String path, String token) {
        return delete(path).header("Authorization", "Bearer " + token);
    }

    private MockHttpServletRequestBuilder authedGet(String path, String token) {
        return get(path).header("Authorization", "Bearer " + token);
    }

    private int status(MockHttpServletRequestBuilder request) throws Exception {
        return mvc.perform(request).andReturn().getResponse().getStatus();
    }

    private JsonNode body(MockHttpServletRequestBuilder request, int expectedStatus) throws Exception {
        var response = mvc.perform(request).andReturn().getResponse();
        assertThat(response.getStatus()).isEqualTo(expectedStatus);
        return objectMapper.readTree(response.getContentAsString(StandardCharsets.UTF_8));
    }
}
