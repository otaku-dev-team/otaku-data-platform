package com.otaku.persona;

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

import java.nio.charset.StandardCharsets;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/**
 * `GET /api/me/profile` 的端到端行为（#401 B2）。
 *
 * <p>为什么必须连真库：三路信号是 `UNION ALL` + `JSON` 标签列，H2 与 mock 都测不出
 * 「tags 读出来是 JSON 字符串、解析失败退回空列表」这类真实形状。
 *
 * <p>走 MockMvc 而不是直调 service：这个接口的**鉴权路径**本身就是要验的东西——
 * 路径挂在 `/api/me/**` 下才会被 `AuthFilter` 拦；如果哪天有人改成 `/api/profile`，
 * 这里应该直接 401 失败，而不是静默变成匿名可读。
 */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class PersonaIntegrationTest {

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
        prefix = "it-persona-" + UUID.randomUUID().toString().substring(0, 8) + "-";
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
    }

    @AfterEach
    void cleanUp() {
        jdbc.update("DELETE FROM user_work_view WHERE user_id = ?", userId);
        jdbc.update("DELETE FROM collection WHERE user_id = ?", userId);
        jdbc.update("DELETE FROM ugc_review WHERE user_id = ?", userId);
        jdbc.update("DELETE FROM work WHERE work_id LIKE ?", prefix + "%");
        jdbc.update("DELETE FROM user_session WHERE user_id = ?", userId);
        jdbc.update("DELETE FROM app_user WHERE id = ?", userId);
    }

    @Test
    @DisplayName("没带令牌 → 401（路径必须在 /api/me/** 下）")
    void requiresAuthentication() throws Exception {
        int status = mvc.perform(get("/api/me/profile")).andReturn().getResponse().getStatus();
        assertThat(status).isEqualTo(401);
    }

    @Test
    @DisplayName("没有任何行为 → 空画像，字段齐全但不给 0.0 假数据")
    void emptyProfile() throws Exception {
        JsonNode body = getProfile();

        assertThat(body.get("sample_size").asInt()).isZero();
        assertThat(body.get("type_weights").isEmpty()).isTrue();
        assertThat(body.get("tag_weights").isEmpty()).isTrue();
        assertThat(body.get("recent_active").isEmpty()).isTrue();
        assertThat(body.get("rating_tendency").get("count").asInt()).isZero();
        assertThat(body.get("rating_tendency").get("mean").isNull()).isTrue();
        assertThat(body.get("rating_tendency").get("dist")).hasSize(10);
        assertThat(body.get("generated_at").asText()).isNotBlank();
    }

    @Test
    @DisplayName("三类信号都参与：类型权重有排序、标签非空、近期活跃带作品 id")
    void aggregatesAllThreeSignalKinds() throws Exception {
        createWork("W-a", "anime", "[\"机战\",\"科幻\"]");
        createWork("W-b", "game", "[\"科幻\"]");
        view("W-a", 3);
        collect("W-a", "watched");
        review("W-b", 9);

        JsonNode body = getProfile();

        assertThat(body.get("sample_size").asInt()).isEqualTo(3);
        // anime: 浏览 1.5 + 看过 4.0 = 5.5；game: 高分点评 3.0 → 归一化 anime=1.0，game≈0.545
        assertThat(body.get("type_weights").get("anime").asDouble()).isEqualTo(1.0);
        assertThat(body.get("type_weights").get("game").asDouble()).isLessThan(1.0);
        assertThat(body.get("tag_weights").has("科幻")).isTrue();
        assertThat(body.get("recent_active")).hasSize(2);
        assertThat(body.get("rating_tendency").get("count").asInt()).isEqualTo(1);
    }

    @Test
    @DisplayName("软删的作品行为仍参与画像（历史偏好不因下架消失）")
    void softDeletedWorkStillCounts() throws Exception {
        createWork("W-gone", "comic", "[\"治愈\"]");
        jdbc.update("UPDATE work SET deleted_at = ? WHERE work_id = ?",
                LocalDateTime.now(ZoneOffset.UTC), "W-gone");
        view("W-gone", 1);

        JsonNode body = getProfile();

        assertThat(body.get("sample_size").asInt()).isEqualTo(1);
        assertThat(body.get("type_weights").get("comic").asDouble()).isEqualTo(1.0);
    }

    @Test
    @DisplayName("导入收藏带来的源站评分进评分倾向：不用写点评也有评分轴（#495）")
    void importedWorkRatingFeedsTendency() throws Exception {
        createRatedWork("W-r1", "[\"机战\"]", "8.60", "0-10");
        createRatedWork("W-r2", "[\"科幻\"]", "6.40", "0-10");
        collect("W-r1", "watched");
        collect("W-r2", "watched");

        JsonNode body = getProfile();

        assertThat(body.get("rating_tendency").get("count").asInt()).isEqualTo(2);
        // 8.60 → 9、6.40 → 6，均值 7.5
        assertThat(body.get("rating_tendency").get("mean").asDouble()).isEqualTo(7.5);
        assertThat(body.get("rating_tendency").get("dist").get(8).asInt()).isEqualTo(1);
        assertThat(body.get("rating_tendency").get("dist").get(5).asInt()).isEqualTo(1);
    }

    @Test
    @DisplayName("自己点评的分覆盖源站均分，同一作品只算一次")
    void ownReviewOverridesWorkRating() throws Exception {
        createRatedWork("W-o1", "[\"机战\"]", "9.20", "0-10");
        collect("W-o1", "watched");
        review("W-o1", 4);

        JsonNode body = getProfile();

        assertThat(body.get("rating_tendency").get("count").asInt()).isEqualTo(1);
        assertThat(body.get("rating_tendency").get("mean").asDouble()).isEqualTo(4.0);
    }

    // ------------------------------------------------------------------

    private JsonNode getProfile() throws Exception {
        String json = mvc.perform(get("/api/me/profile")
                        .header("Authorization", "Bearer " + token))
                .andReturn().getResponse().getContentAsString(StandardCharsets.UTF_8);
        return objectMapper.readTree(json);
    }

    private void createRatedWork(String workId, String tagsJson, String rating, String scale) {
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        jdbc.update("INSERT INTO work (work_id, work_type, title, tags, source, source_id,"
                        + " rating_value, rating_scale, rating_source, created_at, updated_at)"
                        + " VALUES (?, 'anime', ?, ?, 'bangumi', ?, ?, ?, 'bangumi', ?, ?)",
                prefix + workId, "样本 " + workId, tagsJson, prefix + workId,
                new java.math.BigDecimal(rating), scale, now, now);
    }

    private void createWork(String workId, String type, String tagsJson) {
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        jdbc.update("INSERT INTO work (work_id, work_type, title, tags, source, source_id,"
                        + " created_at, updated_at) VALUES (?, ?, ?, ?, 'bangumi', ?, ?, ?)",
                prefix + workId, type, "样本 " + workId, tagsJson, prefix + workId, now, now);
    }

    private void view(String workId, int count) {
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        jdbc.update("INSERT INTO user_work_view (user_id, work_id, first_viewed_at, last_viewed_at,"
                        + " view_count) VALUES (?, ?, ?, ?, ?)",
                userId, prefix + workId, now, now, count);
    }

    private void collect(String workId, String status) {
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        jdbc.update("INSERT INTO collection (user_id, work_id, status, created_at, updated_at)"
                + " VALUES (?, ?, ?, ?, ?)", userId, prefix + workId, status, now, now);
    }

    private void review(String workId, int rating) {
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        jdbc.update("INSERT INTO ugc_review (site_key, work_id, user_id, rating, status,"
                        + " created_at, updated_at) VALUES ('otaku_site', ?, ?, ?, 'published', ?, ?)",
                prefix + workId, userId, rating, now, now);
    }
}
