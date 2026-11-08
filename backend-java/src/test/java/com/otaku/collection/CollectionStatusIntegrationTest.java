package com.otaku.collection;

import com.otaku.common.SessionTokens;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.UUID;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.patch;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * 收藏第 4 态「抛弃」（`dropped`，#496）的端到端行为。
 *
 * <p>为什么必须连真库：`status` 是 `VARCHAR(16)` 且**没有 CHECK 约束**——「加一个枚举值
 * 不用迁移」这句话的正确性，只有真 MySQL 才能证明；H2 的列约束与生产不是一套。
 *
 * <p>走 MockMvc 而不是直调 service：`/api/me/**` 的鉴权路径本身要被覆盖，
 * 而且「PATCH 不存在的记录 → 409」这类语义只在 HTTP 层才看得见。
 */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class CollectionStatusIntegrationTest {

    @Autowired
    private MockMvc mvc;

    @Autowired
    private JdbcTemplate jdbc;

    private String prefix;
    private String token;
    private long userId;

    @BeforeEach
    void setUp() {
        prefix = "it-drop-" + UUID.randomUUID().toString().substring(0, 8) + "-";
        token = SessionTokens.newToken();
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);

        jdbc.update("INSERT INTO app_user (user_id, username, password_hash, created_at, updated_at)"
                        + " VALUES (?, ?, ?, ?, ?)",
                prefix + "u", prefix + "name", "x", now, now);
        userId = jdbc.queryForObject("SELECT id FROM app_user WHERE user_id = ?", Long.class, prefix + "u");

        jdbc.update("INSERT INTO user_session (token_hash, user_id, created_at, expires_at)"
                        + " VALUES (?, ?, ?, ?)",
                SessionTokens.hash(token), userId, now, now.plusDays(30));

        jdbc.update("INSERT INTO work (work_id, work_type, title, tags, source, source_id,"
                        + " created_at, updated_at) VALUES (?, 'anime', '样本', '[]', 'bangumi', ?, ?, ?)",
                prefix + "w", prefix + "w", now, now);
    }

    @AfterEach
    void cleanUp() {
        jdbc.update("DELETE FROM collection WHERE user_id = ?", userId);
        jdbc.update("DELETE FROM work WHERE work_id LIKE ?", prefix + "%");
        jdbc.update("DELETE FROM user_session WHERE user_id = ?", userId);
        jdbc.update("DELETE FROM app_user WHERE id = ?", userId);
    }

    @Test
    @DisplayName("PUT dropped 能存下——status 列没有 CHECK 约束，加第 4 态不需要迁移")
    void droppedIsAcceptedAndListed() throws Exception {
        mvc.perform(put("/api/me/collections/" + prefix + "w")
                        .header("Authorization", "Bearer " + token)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"status\":\"dropped\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("dropped"))
                .andExpect(jsonPath("$.collected").value(true));

        mvc.perform(get("/api/me/collections?status=dropped")
                        .header("Authorization", "Bearer " + token))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.total").value(1))
                .andExpect(jsonPath("$.items[0].status").value("dropped"));
    }

    @Test
    @DisplayName("抛弃不锁定状态：用户改主意可以直接 PATCH 回 want")
    void droppedCanBeOverwritten() throws Exception {
        mvc.perform(put("/api/me/collections/" + prefix + "w")
                        .header("Authorization", "Bearer " + token)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"status\":\"dropped\"}"))
                .andExpect(status().isOk());

        mvc.perform(patch("/api/me/collections/" + prefix + "w")
                        .header("Authorization", "Bearer " + token)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"status\":\"want\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("want"));

        mvc.perform(get("/api/me/collections?status=dropped")
                        .header("Authorization", "Bearer " + token))
                .andExpect(jsonPath("$.total").value(0));
    }

    @Test
    @DisplayName("非法状态仍然 400，且不会把已有状态改坏")
    void invalidStatusRejectedWithoutSideEffect() throws Exception {
        mvc.perform(put("/api/me/collections/" + prefix + "w")
                        .header("Authorization", "Bearer " + token)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"status\":\"want\"}"))
                .andExpect(status().isOk());

        mvc.perform(put("/api/me/collections/" + prefix + "w")
                        .header("Authorization", "Bearer " + token)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"status\":\"abandoned\"}"))
                .andExpect(status().isBadRequest());

        mvc.perform(get("/api/me/collections/" + prefix + "w")
                        .header("Authorization", "Bearer " + token))
                .andExpect(jsonPath("$.status").value("want"));
    }
}
