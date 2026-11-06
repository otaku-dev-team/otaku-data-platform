package com.otaku.recommend;

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

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/**
 * `GET /api/me/recommend` 的端到端行为（#402）。
 *
 * <p>为什么必须连真库：候选召回走 `work_tag` 的输出、排除已看走 `UNION` 两张个人表、
 * 冷启动走 `rating_sort` 生成列——这三处都是 SQL 语义，mock 掉等于没测。
 *
 * <p>顺便盯住鉴权：推荐是基于个人行为的，路径必须在 `/api/me/**` 下。
 */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class RecommendIntegrationTest {

    @Autowired
    private MockMvc mvc;

    @Autowired
    private JdbcTemplate jdbc;

    @Autowired
    private ObjectMapper objectMapper;

    private String prefix;
    private String token;
    private long userId;

    @BeforeEach
    void setUp() {
        prefix = "it-rec-" + UUID.randomUUID().toString().substring(0, 8) + "-";
        token = SessionTokens.newToken();

        jdbc.update("INSERT INTO app_user (user_id, username, password_hash, created_at, updated_at)"
                        + " VALUES (?, ?, ?, ?, ?)",
                prefix + "u", prefix + "name", "x",
                LocalDateTime.now(ZoneOffset.UTC), LocalDateTime.now(ZoneOffset.UTC));
        userId = jdbc.queryForObject("SELECT id FROM app_user WHERE user_id = ?", Long.class, prefix + "u");
        jdbc.update("INSERT INTO user_session (token_hash, user_id, created_at, expires_at)"
                        + " VALUES (?, ?, ?, ?)",
                SessionTokens.hash(token), userId,
                LocalDateTime.now(ZoneOffset.UTC), LocalDateTime.now(ZoneOffset.UTC).plusDays(30));

        // 库里的 work_tag 是导入时写的；这里手工补一份，召回才有输入。
        createWork("W-liked", "anime", 9.0, 200, "机战");
        createWork("W-seen", "anime", 8.5, 200, "机战");
        createWork("W-cand", "anime", 8.0, 200, "机战");
    }

    @AfterEach
    void cleanUp() {
        jdbc.update("DELETE FROM user_work_view WHERE user_id = ?", userId);
        jdbc.update("DELETE FROM collection WHERE user_id = ?", userId);
        jdbc.update("DELETE FROM work_tag WHERE work_ref IN (SELECT id FROM work WHERE work_id LIKE ?)",
                prefix + "%");
        jdbc.update("DELETE FROM work WHERE work_id LIKE ?", prefix + "%");
        jdbc.update("DELETE FROM user_session WHERE user_id = ?", userId);
        jdbc.update("DELETE FROM app_user WHERE id = ?", userId);
    }

    @Test
    @DisplayName("没带令牌 → 401（路径必须在 /api/me/** 下）")
    void requiresAuthentication() throws Exception {
        int status = mvc.perform(get("/api/me/recommend")).andReturn().getResponse().getStatus();
        assertThat(status).isEqualTo(401);
    }

    @Test
    @DisplayName("画像为空 → 冷启动热门榜，cold_start=true")
    void coldStartReturnsPopular() throws Exception {
        JsonNode body = getRecommend(null);

        assertThat(body.get("cold_start").asBoolean()).isTrue();
        assertThat(body.get("items")).isNotEmpty();
        assertThat(body.get("items").get(0).get("reasons")).isEmpty();
    }

    @Test
    @DisplayName("有行为 → 按标签召回，排除已看/已收藏，reasons 带命中标签")
    void recommendsByTagAndExcludesTouched() throws Exception {
        collect("W-liked", "watched");
        view("W-seen");

        JsonNode body = getRecommend("10");

        assertThat(body.get("cold_start").asBoolean()).isFalse();
        var ids = new java.util.ArrayList<String>();
        body.get("items").forEach(item -> ids.add(item.get("work").get("work_id").asText()));
        assertThat(ids).contains(prefix + "W-cand");
        assertThat(ids).doesNotContain(prefix + "W-liked", prefix + "W-seen");
        assertThat(body.get("items").get(0).get("score").asDouble()).isEqualTo(1.0);
        assertThat(body.get("items").get(0).get("reasons").toString()).contains("机战");
    }

    // ------------------------------------------------------------------

    private JsonNode getRecommend(String limit) throws Exception {
        var request = get("/api/me/recommend").header("Authorization", "Bearer " + token);
        if (limit != null) {
            request = request.param("limit", limit);
        }
        String json = mvc.perform(request).andReturn().getResponse()
                .getContentAsString(StandardCharsets.UTF_8);
        return objectMapper.readTree(json);
    }

    private void createWork(String workId, String type, double rating, int ratingCount, String tag) {
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        String fullId = prefix + workId;
        jdbc.update("INSERT INTO work (work_id, work_type, title, tags, rating_value, rating_scale,"
                        + " rating_source, rating_count, source, source_id, created_at, updated_at)"
                        + " VALUES (?, ?, ?, ?, ?, '0-10', 'bangumi', ?, 'bangumi', ?, ?, ?)",
                fullId, type, "样本 " + workId, "[\"" + tag + "\"]",
                BigDecimal.valueOf(rating), ratingCount, fullId, now, now);
        Long workRef = jdbc.queryForObject("SELECT id FROM work WHERE work_id = ?", Long.class, fullId);
        jdbc.update("INSERT INTO work_tag (work_ref, tag, work_type, rating_value) VALUES (?, ?, ?, ?)",
                workRef, tag, type, BigDecimal.valueOf(rating));
    }

    private void collect(String workId, String status) {
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        jdbc.update("INSERT INTO collection (user_id, work_id, status, created_at, updated_at)"
                + " VALUES (?, ?, ?, ?, ?)", userId, prefix + workId, status, now, now);
    }

    private void view(String workId) {
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        jdbc.update("INSERT INTO user_work_view (user_id, work_id, first_viewed_at, last_viewed_at,"
                        + " view_count) VALUES (?, ?, ?, ?, 1)",
                userId, prefix + workId, now, now);
    }
}
