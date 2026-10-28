package com.otaku.auth;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.auth.site.SiteAuthClient;
import com.otaku.auth.site.SiteAuthException;
import com.otaku.auth.site.SiteAuthFailure;
import com.otaku.auth.site.SiteTokenResponse;
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
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.BDDMockito.given;
import static org.mockito.BDDMockito.willThrow;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * 站点授权票据换平台会话（#242）的全链路约束，跑在**真 MySQL** 上。
 *
 * <p>为什么必须连真库：验的是 {@code uk_identity (identity_source, external_user_id)}
 * 这个唯一键的「重登映射恒定」与「站点令牌只存哈希」，都是 MySQL 方言；
 * Mock 掉仓储就只剩 Java 分支，什么也证明不了。
 *
 * <p>站点出站口 {@link SiteAuthClient} 换成桩：本类验的是平台侧行为，
 * 真 HTTP 解析在 {@code HttpSiteAuthClientTest} 里用本地 HTTP 服务验。
 */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class SiteLoginIntegrationTest {

    /** 测试数据前缀：只清理本类造出来的行，不碰真实账号。 */
    private static final String EXT_PREFIX = "it-site-";
    private static final String USER_ID_PREFIX = "U-IT";

    @Autowired
    private MockMvc mockMvc;

    @Autowired
    private JdbcTemplate jdbc;

    @Autowired
    private ObjectMapper objectMapper;

    @MockitoBean
    private SiteAuthClient siteAuthClient;

    private String externalUserId;

    @BeforeEach
    void setUp() {
        externalUserId = EXT_PREFIX + System.nanoTime();
    }

    @AfterEach
    void cleanUp() {
        // user_session 有外键指向 app_user，先删会话再删账号。
        jdbc.update("""
                DELETE FROM user_session WHERE user_id IN
                  (SELECT id FROM app_user WHERE external_user_id LIKE ?)
                """, EXT_PREFIX + "%");
        jdbc.update("DELETE FROM app_user WHERE external_user_id LIKE ?", EXT_PREFIX + "%");
    }

    @Test
    @DisplayName("票据换会话：建映射账号、只存站点令牌哈希、平台令牌可访问 /api/auth/me")
    void exchangesTicketForPlatformSession() throws Exception {
        given(siteAuthClient.exchange("ticket-ok"))
                .willReturn(new SiteTokenResponse("site-token-1", externalUserId, "路人甲", "https://img/a.png"));

        JsonNode body = postSiteLogin("ticket-ok", 200);

        String platformToken = body.path("token").asText();
        assertThat(platformToken).isNotBlank();
        assertThat(body.path("user").path("display_name").asText()).isEqualTo("路人甲");
        assertThat(body.path("user").path("username").asText()).startsWith("site_");

        // 平台令牌能通过既有鉴权链路（契约 §6 步 2 的验收判据）。
        mockMvc.perform(get("/api/auth/me").header("Authorization", "Bearer " + platformToken))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.user_id").value(body.path("user").path("user_id").asText()));

        Map<String, Object> row = jdbc.queryForMap("""
                SELECT identity_source, external_user_id, site_token_hash, site_token_expires_at, password_hash
                  FROM app_user WHERE external_user_id = ?
                """, externalUserId);
        assertThat(row.get("identity_source")).isEqualTo("otaku_site");
        // 只存哈希：库里既不是原文，也确实是 SHA-256。
        assertThat(row.get("site_token_hash")).isEqualTo(SessionTokens.hash("site-token-1"));
        assertThat((String) row.get("site_token_hash")).isNotEqualTo("site-token-1");
        assertThat(row.get("site_token_expires_at")).isNotNull();
        // 站点账号没有口令，占位摘要必须是 BCrypt 且不可逆。
        assertThat((String) row.get("password_hash")).startsWith("$2");
    }

    @Test
    @DisplayName("同一站点身份重登：映射恒定（不新建账号），站点令牌哈希被刷新")
    void repeatedLoginKeepsSameAccount() throws Exception {
        given(siteAuthClient.exchange("ticket-1"))
                .willReturn(new SiteTokenResponse("site-token-1", externalUserId, null, null));
        String userId = postSiteLogin("ticket-1", 200).path("user").path("user_id").asText();

        given(siteAuthClient.exchange("ticket-2"))
                .willReturn(new SiteTokenResponse("site-token-2", externalUserId, null, null));
        String secondUserId = postSiteLogin("ticket-2", 200).path("user").path("user_id").asText();

        assertThat(secondUserId).isEqualTo(userId);
        Integer count = jdbc.queryForObject(
                "SELECT COUNT(*) FROM app_user WHERE external_user_id = ?", Integer.class, externalUserId);
        assertThat(count).isEqualTo(1);
        String hash = jdbc.queryForObject(
                "SELECT site_token_hash FROM app_user WHERE external_user_id = ?", String.class, externalUserId);
        assertThat(hash).isEqualTo(SessionTokens.hash("site-token-2"));
    }

    @Test
    @DisplayName("站点拒绝（票据过期/secret 错）：401，且站点 detail 原文不得出现在响应里")
    void rejectedTicketIsNormalizedToOneSpace() throws Exception {
        willThrow(new SiteAuthException(SiteAuthFailure.AUTH_FAILED, "站点拒绝了本次授权", "invalid_client"))
                .given(siteAuthClient).exchange(anyString());

        MvcResult result = mockMvc.perform(post("/api/auth/site-login")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"ticket\":\"expired\"}"))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error.code").value("INVALID_CREDENTIALS"))
                .andReturn();

        // 契约 §7：站点 FastAPI 的 detail 原文只进服务端日志，绝不透传客户端。
        assertThat(result.getResponse().getContentAsString()).doesNotContain("invalid_client");
        assertThat(result.getResponse().getContentAsString()).doesNotContain("detail");
    }

    @Test
    @DisplayName("站点不可用（超时/5xx）：503 SITE_UNAVAILABLE——不是 401，避免把用户推进必然失败的重试")
    void unavailableSiteIs503() throws Exception {
        willThrow(new SiteAuthException(SiteAuthFailure.UNAVAILABLE, "站点暂不可用", null))
                .given(siteAuthClient).exchange(anyString());

        mockMvc.perform(post("/api/auth/site-login")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"ticket\":\"ticket-x\"}"))
                .andExpect(status().isServiceUnavailable())
                .andExpect(jsonPath("$.error.code").value("SITE_UNAVAILABLE"));
    }

    @Test
    @DisplayName("缺票据：400，连站点都不用请求")
    void blankTicketIsBadRequest() throws Exception {
        mockMvc.perform(post("/api/auth/site-login")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"ticket\":\"  \"}"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error.code").value("BAD_REQUEST"));
    }

    @Test
    @DisplayName("映射账号被站点管理员禁用：403 USER_DISABLED，不发会话")
    void disabledMappedAccountCannotLogin() throws Exception {
        given(siteAuthClient.exchange("ticket-1"))
                .willReturn(new SiteTokenResponse("site-token-1", externalUserId, null, null));
        postSiteLogin("ticket-1", 200);
        jdbc.update("UPDATE app_user SET status = 'disabled' WHERE external_user_id = ?", externalUserId);

        given(siteAuthClient.exchange("ticket-2"))
                .willReturn(new SiteTokenResponse("site-token-2", externalUserId, null, null));
        postSiteLogin("ticket-2", 403);
        mockMvc.perform(post("/api/auth/site-login")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"ticket\":\"ticket-2\"}"))
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.error.code").value("USER_DISABLED"));
    }

    private JsonNode postSiteLogin(String ticket, int expectedStatus) throws Exception {
        MvcResult result = mockMvc.perform(post("/api/auth/site-login")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"ticket\":\"" + ticket + "\"}"))
                .andExpect(status().is(expectedStatus))
                .andReturn();
        return objectMapper.readTree(result.getResponse().getContentAsString());
    }
}
