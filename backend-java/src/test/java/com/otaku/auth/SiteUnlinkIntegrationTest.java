package com.otaku.auth;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.auth.site.SiteAuthClient;
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
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;

import java.time.LocalDateTime;
import java.time.ZoneOffset;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.BDDMockito.given;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/**
 * 「断开与网站的连接」（`POST /api/auth/site-unlink`）+ `User.identity_source` 的端到端行为。
 *
 * <p>对应契约 `identity-linkup-contract.md` §5 三态②，以及 W1 `w1-login-dual-entry.md`
 * §5 给后端的三条输入里的第 1、2 条。
 *
 * <p>为什么必须连真库：验的是「清 `identity_source` 但保留 `external_user_id` 与账号行」
 * 和「按 `external_user_id` 接回原账号」——这两条全靠 `app_user` 的真实列与唯一键，
 * mock 仓储只会证明 Java 分支跑过。为什么走 MockMvc：`/api/auth/site-unlink` 是精确路径，
 * 只有过 {@code AuthFilter} 才有 `ATTRIBUTE_USER`；这条路径漏进白名单的表现是 400 而不是 401，
 * 单测 Service 根本抓不到（2026-10-30 的 `/api/me` 就是这么翻的车）。
 */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class SiteUnlinkIntegrationTest {

    /** 测试数据前缀：只清理本类造出来的行，不碰真实账号。 */
    private static final String EXT_PREFIX = "it-unlink-";
    private static final String USER_ID_PREFIX = "U-ITUNLINK-";

    @Autowired
    private MockMvc mvc;

    @Autowired
    private JdbcTemplate jdbc;

    @Autowired
    private ObjectMapper objectMapper;

    @MockitoBean
    private SiteAuthClient siteAuthClient;

    private String externalUserId;
    private String platformToken;
    private long platformUserPk;

    @BeforeEach
    void setUp() {
        externalUserId = EXT_PREFIX + System.nanoTime();
        platformToken = SessionTokens.newToken();
        platformUserPk = createPlatformUser(platformToken);
    }

    @AfterEach
    void cleanUp() {
        // collection / user_session 都有外键指向 app_user，先删子表。
        jdbc.update("""
                DELETE FROM collection WHERE user_id IN
                  (SELECT id FROM app_user WHERE external_user_id LIKE ? OR user_id LIKE ?)
                """, EXT_PREFIX + "%", USER_ID_PREFIX + "%");
        jdbc.update("""
                DELETE FROM user_session WHERE user_id IN
                  (SELECT id FROM app_user WHERE external_user_id LIKE ? OR user_id LIKE ?)
                """, EXT_PREFIX + "%", USER_ID_PREFIX + "%");
        jdbc.update("DELETE FROM app_user WHERE external_user_id LIKE ? OR user_id LIKE ?",
                EXT_PREFIX + "%", USER_ID_PREFIX + "%");
    }

    @Test
    @DisplayName("identity_source：平台账号为 null，站点账号为 otaku_site，两者从 /me 读到的是同一份")
    void identitySourceIsExposed() throws Exception {
        assertThat(meBody(platformToken).path("identity_source").isNull()).isTrue();

        String siteToken = siteLogin("ticket-me").path("token").asText();
        // site-login 的响应本身也要带（客户端拿到会话的第一刻就要知道该显示哪套菜单）
        assertThat(siteLogin("ticket-me-2").path("user").path("identity_source").asText())
                .isEqualTo("otaku_site");
        assertThat(meBody(siteToken).path("identity_source").asText()).isEqualTo("otaku_site");
    }

    @Test
    @DisplayName("断开：清身份列与令牌哈希、保留账号与 external_user_id、撤销全部会话")
    void unlinkClearsIdentityButKeepsAccount() throws Exception {
        String token = siteLogin("ticket-1").path("token").asText();
        String userId = meBody(token).path("user_id").asText();
        long userPk = pkOf(userId);
        insertCollection(userPk, "W-keep-1");

        // 第二台设备的会话：断开是账号级动作，两条都得撤。
        String otherDevice = SessionTokens.newToken();
        jdbc.update("INSERT INTO user_session (token_hash, user_id, created_at, expires_at)"
                + " VALUES (?, ?, ?, ?)", SessionTokens.hash(otherDevice), userPk,
                LocalDateTime.now(ZoneOffset.UTC), LocalDateTime.now(ZoneOffset.UTC).plusDays(30));

        assertThat(status(withAuth(post("/api/auth/site-unlink"), token))).isEqualTo(204);

        var row = jdbc.queryForMap("""
                SELECT identity_source, external_user_id, site_token_hash, site_token_expires_at,
                       status, deleted_at
                  FROM app_user WHERE id = ?
                """, userPk);
        assertThat(row.get("identity_source")).isNull();
        assertThat(row.get("site_token_hash")).isNull();
        assertThat(row.get("site_token_expires_at")).isNull();
        // 重连的锚点，必须留着——否则「断开再连」只能新建账号。
        assertThat(row.get("external_user_id")).isEqualTo(externalUserId);
        // 账号没有被注销。
        assertThat(row.get("status")).isEqualTo("active");
        assertThat(row.get("deleted_at")).isNull();
        // 数据还在。
        Integer kept = jdbc.queryForObject(
                "SELECT COUNT(*) FROM collection WHERE user_id = ?", Integer.class, userPk);
        assertThat(kept).isEqualTo(1);
        // 全部会话失效：当前这台与另一台都拿不到 /me。
        assertThat(status(withAuth(get("/api/auth/me"), token))).isEqualTo(401);
        assertThat(status(withAuth(get("/api/auth/me"), otherDevice))).isEqualTo(401);
        Integer live = jdbc.queryForObject(
                "SELECT COUNT(*) FROM user_session WHERE user_id = ? AND revoked_at IS NULL",
                Integer.class, userPk);
        assertThat(live).isZero();
    }

    @Test
    @DisplayName("重连接回原账号：user_id 与收藏都不变，令牌哈希刷新")
    void relinkKeepsSameAccountAndData() throws Exception {
        String first = siteLogin("ticket-a").path("token").asText();
        String userId = meBody(first).path("user_id").asText();
        long userPk = pkOf(userId);
        insertCollection(userPk, "W-keep-2");

        assertThat(status(withAuth(post("/api/auth/site-unlink"), first))).isEqualTo(204);

        JsonNode again = siteLogin("ticket-b");
        assertThat(again.path("user").path("user_id").asText()).isEqualTo(userId);
        Integer count = jdbc.queryForObject(
                "SELECT COUNT(*) FROM app_user WHERE external_user_id = ?", Integer.class, externalUserId);
        assertThat(count).isEqualTo(1);

        var row = jdbc.queryForMap("""
                SELECT identity_source, site_token_hash FROM app_user WHERE id = ?
                """, userPk);
        assertThat(row.get("identity_source")).isEqualTo("otaku_site");
        assertThat(row.get("site_token_hash")).isEqualTo(SessionTokens.hash("site-token-b"));
        assertThat(meBody(again.path("token").asText()).path("identity_source").asText())
                .isEqualTo("otaku_site");
    }

    @Test
    @DisplayName("平台账号调断开：409 NOT_SITE_LINKED，账号与会话都不动")
    void platformAccountCannotUnlink() throws Exception {
        MvcResult result = mvc.perform(withAuth(post("/api/auth/site-unlink"), platformToken))
                .andReturn();
        assertThat(result.getResponse().getStatus()).isEqualTo(409);
        assertThat(result.getResponse().getContentAsString()).contains("NOT_SITE_LINKED");

        // 会话仍然有效，账号没被碰过。
        assertThat(status(withAuth(get("/api/auth/me"), platformToken))).isEqualTo(200);
        Integer live = jdbc.queryForObject(
                "SELECT COUNT(*) FROM user_session WHERE user_id = ? AND revoked_at IS NULL",
                Integer.class, platformUserPk);
        assertThat(live).isEqualTo(1);
    }

    @Test
    @DisplayName("没带令牌 → 401（这条路径不在 /api/me/** 下，靠 AuthFilter 的精确白名单）")
    void unlinkRequiresAuthentication() throws Exception {
        assertThat(status(post("/api/auth/site-unlink"))).isEqualTo(401);
    }

    @Test
    @DisplayName("已注销的账号不会被「重新授权」复活：403 USER_DISABLED")
    void deletedAccountIsNotResurrectedByRelink() throws Exception {
        String token = siteLogin("ticket-x").path("token").asText();
        long userPk = pkOf(meBody(token).path("user_id").asText());
        assertThat(status(withAuth(post("/api/auth/site-unlink"), token))).isEqualTo(204);

        // 断开后再走 DELETE /api/me（会话已撤销，这里直接落库模拟那一步的终态）。
        jdbc.update("UPDATE app_user SET status = 'disabled', deleted_at = NOW(3) WHERE id = ?", userPk);

        // 站点侧这次授权是成功的（票据有效、站点给了新令牌），被拦的是平台侧的状态。
        given(siteAuthClient.exchange("ticket-y"))
                .willReturn(new SiteTokenResponse("site-token-y", externalUserId, null, null));
        MvcResult result = mvc.perform(post("/api/auth/site-login")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"ticket\":\"ticket-y\"}"))
                .andReturn();
        assertThat(result.getResponse().getStatus()).isEqualTo(403);
        assertThat(result.getResponse().getContentAsString()).contains("USER_DISABLED");
    }

    // ── 辅助 ────────────────────────────────────────────────────────────

    private JsonNode siteLogin(String ticket) throws Exception {
        given(siteAuthClient.exchange(ticket))
                .willReturn(new SiteTokenResponse("site-token-" + ticket.substring("ticket-".length()),
                        externalUserId, null, null));
        MvcResult result = mvc.perform(post("/api/auth/site-login")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"ticket\":\"" + ticket + "\"}"))
                .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers
                        .status().isOk())
                .andReturn();
        return objectMapper.readTree(result.getResponse().getContentAsString());
    }

    private JsonNode meBody(String token) throws Exception {
        MvcResult result = mvc.perform(withAuth(get("/api/auth/me"), token))
                .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers
                        .status().isOk())
                .andReturn();
        return objectMapper.readTree(result.getResponse().getContentAsString());
    }

    private int status(MockHttpServletRequestBuilder request) throws Exception {
        return mvc.perform(request).andReturn().getResponse().getStatus();
    }

    private MockHttpServletRequestBuilder withAuth(MockHttpServletRequestBuilder request, String token) {
        return request.header("Authorization", "Bearer " + token);
    }

    private long createPlatformUser(String token) {
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        String userId = USER_ID_PREFIX + System.nanoTime();
        jdbc.update("INSERT INTO app_user (user_id, username, password_hash, created_at, updated_at)"
                + " VALUES (?, ?, ?, ?, ?)", userId, userId, "x", now, now);
        Long id = jdbc.queryForObject("SELECT id FROM app_user WHERE user_id = ?", Long.class, userId);
        jdbc.update("INSERT INTO user_session (token_hash, user_id, created_at, expires_at)"
                + " VALUES (?, ?, ?, ?)", SessionTokens.hash(token), id, now, now.plusDays(30));
        return id;
    }

    private long pkOf(String userId) {
        Long id = jdbc.queryForObject("SELECT id FROM app_user WHERE user_id = ?", Long.class, userId);
        return id == null ? -1 : id;
    }

    /** collection.work_id 不建外键（作品同步与个人数据解耦），可以塞假 id。 */
    private void insertCollection(long userPk, String workId) {
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        jdbc.update("INSERT INTO collection (user_id, work_id, created_at, updated_at)"
                + " VALUES (?, ?, ?, ?)", userPk, workId, now, now);
    }
}
