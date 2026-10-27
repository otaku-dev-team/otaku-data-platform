package com.otaku.console;

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
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;

import java.nio.charset.StandardCharsets;
import java.time.LocalDateTime;
import java.time.ZoneOffset;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/**
 * 站主后台的隔离与禁用语义，跑在**真 MySQL** 上（MockMvc 走完整过滤器链）。
 *
 * <p>为什么必须是集成测试而不是单元测试：
 * <ul>
 *   <li>「A 站看不到 B 站数据」这条，单元测试只能证明"我把参数传对了"，
 *       证明不了 SQL 里那条 {@code where site_key = ?} 真的在；</li>
 *   <li>「禁用当场生效」要跨 {@code app_user} 与 {@code user_session} 两张表，
 *       还要走一遍真实的登录接口才算数；</li>
 *   <li>403/404 的分流经过过滤器与异常处理器，只有真发一次请求才知道到底返回了什么。</li>
 * </ul>
 *
 * <p>没设 {@code IT_DB_PORT} 时整类跳过（与其它集成测试一致），CI 里一定会设。
 */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class ConsoleIsolationIntegrationTest {

    private static final String INTERNAL_TOKEN = "it-token";
    private static final String SITE_A = "it-console-site-a";
    private static final String SITE_B = "it-console-site-b";
    private static final String SRC_A = "it_console_src_a";
    private static final String SRC_B = "it_console_src_b";
    private static final String ADMIN_A = "it-console-admin-a";
    private static final String ADMIN_B = "it-console-admin-b";
    private static final String PASSWORD = "console-pass-1";

    @Autowired
    private MockMvc mvc;

    @Autowired
    private JdbcTemplate jdbc;

    @Autowired
    private ObjectMapper objectMapper;

    /**
     * 用例前后各清一次（失败时 {@code @AfterEach} 也会跑，但仍放进 {@code @BeforeEach}：
     * 上一次运行被中断留下的行不能毒到这一次）。
     *
     * <p>顺序必须从子表往父表删：{@code user_session → app_user}、
     * {@code site_admin_session → site_admin}、{@code site_source/site_admin/app_user → site}。
     * 第一次写这个清理时漏了 {@code user_session}，外键当场把整轮测试打红。
     */
    @BeforeEach
    @AfterEach
    void cleanUp() {
        jdbc.update("DELETE FROM user_session WHERE user_id IN "
                + "(SELECT id FROM app_user WHERE site_key IN (?, ?) OR username LIKE 'it-console-%')",
                SITE_A, SITE_B);
        jdbc.update("DELETE FROM site_admin_session WHERE site_admin_id IN "
                + "(SELECT id FROM site_admin WHERE site_key IN (?, ?))", SITE_A, SITE_B);
        jdbc.update("DELETE FROM app_user WHERE site_key IN (?, ?) OR username LIKE 'it-console-%'",
                SITE_A, SITE_B);
        jdbc.update("DELETE FROM site_admin WHERE site_key IN (?, ?)", SITE_A, SITE_B);
        jdbc.update("DELETE FROM site_source WHERE site_key IN (?, ?)", SITE_A, SITE_B);
        jdbc.update("DELETE FROM site WHERE site_key IN (?, ?)", SITE_A, SITE_B);
        jdbc.update("DELETE FROM import_batch_run WHERE batch_id LIKE 'it-console-%'");
        jdbc.update("DELETE FROM import_batch WHERE batch_id LIKE 'it-console-%'");
        jdbc.update("DELETE FROM work WHERE source IN (?, ?)", SRC_A, SRC_B);
    }

    // ------------------------------------------------------------------ 隔离

    @Test
    @DisplayName("用户列表只含本站账号：未归属站点的历史账号同样不可见")
    void userListIsScopedToOwnSite() throws Exception {
        twoSites();
        createAccount("it-console-a-user", SITE_A);
        createAccount("it-console-b-user", SITE_B);
        createAccount("it-console-orphan", null);

        String tokenA = loginAdmin(ADMIN_A);
        JsonNode page = okJson(get("/api/console/users").header("Authorization", "Bearer " + tokenA));

        assertThat(page.get("total").asInt()).isEqualTo(1);
        assertThat(page.get("items").get(0).get("username").asText()).isEqualTo("it-console-a-user");
    }

    @Test
    @DisplayName("禁用别的站点用户 → 403（不是 404，也不能静默成功）")
    void cannotDisableUserOfAnotherSite() throws Exception {
        twoSites();
        String bUser = createAccount("it-console-b-user", SITE_B);

        String tokenA = loginAdmin(ADMIN_A);
        MvcResult result = mvc.perform(post("/api/console/users/" + bUser + "/disable")
                        .header("Authorization", "Bearer " + tokenA)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"reason\":\"越权测试\"}"))
                .andReturn();

        assertThat(result.getResponse().getStatus()).isEqualTo(403);
        assertThat(errorCode(result)).isEqualTo("FORBIDDEN");
        // 副作用必须没有发生
        assertThat(userStatus(bUser)).isEqualTo("active");
    }

    @Test
    @DisplayName("未归属站点的账号：任何站主都禁不了（403），也不会出现在列表里")
    void orphanUserIsInvisibleAndNotDisableable() throws Exception {
        twoSites();
        String orphan = createAccount("it-console-orphan", null);

        String tokenA = loginAdmin(ADMIN_A);
        MvcResult result = mvc.perform(post("/api/console/users/" + orphan + "/disable")
                        .header("Authorization", "Bearer " + tokenA))
                .andReturn();

        assertThat(result.getResponse().getStatus()).isEqualTo(403);
        assertThat(userStatus(orphan)).isEqualTo("active");
    }

    @Test
    @DisplayName("账号不存在 → 404（与越权的 403 分开，便于排查）")
    void unknownUserIs404() throws Exception {
        twoSites();
        String tokenA = loginAdmin(ADMIN_A);

        MvcResult result = mvc.perform(post("/api/console/users/U-notexist/disable")
                        .header("Authorization", "Bearer " + tokenA))
                .andReturn();

        assertThat(result.getResponse().getStatus()).isEqualTo(404);
        assertThat(errorCode(result)).isEqualTo("USER_NOT_FOUND");
    }

    @Test
    @DisplayName("概览只统计本站来源的作品")
    void overviewCountsOnlyOwnSources() throws Exception {
        twoSites();
        insertWork(SRC_A, "a-1", "本站作品一");
        insertWork(SRC_A, "a-2", "本站作品二");
        insertWork(SRC_B, "b-1", "别站作品一");

        String tokenA = loginAdmin(ADMIN_A);
        JsonNode overview = okJson(get("/api/console/overview").header("Authorization", "Bearer " + tokenA));

        assertThat(overview.get("works").get("total").asInt()).isEqualTo(2);
        assertThat(overview.get("coverage").get("total").asInt()).isEqualTo(2);
        assertThat(overview.get("sources").toString()).contains(SRC_A).doesNotContain(SRC_B);
    }

    @Test
    @DisplayName("同步状态只含本站来源的运行；没有记录时是 never 而不是 0 条假成功")
    void syncStatusIsScopedAndHonest() throws Exception {
        twoSites();
        insertBatchRun("it-console-batch-a", SRC_A, 3, 0, finishedMinutesAgo(30));
        insertBatchRun("it-console-batch-b", SRC_B, 0, 5, finishedMinutesAgo(10));

        String tokenA = loginAdmin(ADMIN_A);
        JsonNode sync = okJson(get("/api/console/sync").header("Authorization", "Bearer " + tokenA));

        assertThat(sync.get("recent_runs")).hasSize(1);
        assertThat(sync.get("recent_runs").get(0).get("batch_id").asText()).isEqualTo("it-console-batch-a");
        assertThat(sync.get("summary").get("status").asText()).isEqualTo("ok");

        // 另一个站点一条同步记录都没有 → never
        String tokenB = loginAdmin(ADMIN_B);
        jdbc.update("DELETE FROM import_batch_run WHERE batch_id = 'it-console-batch-b'");
        JsonNode syncB = okJson(get("/api/console/sync").header("Authorization", "Bearer " + tokenB));
        assertThat(syncB.get("summary").get("status").asText()).isEqualTo("never");
    }

    // ------------------------------------------------------------------ 禁用

    @Test
    @DisplayName("禁用本站用户：当场撤销会话 → 旧令牌立刻失效，再用原密码登录得 403 USER_DISABLED")
    void disableRevokesSessionsAndBlocksLogin() throws Exception {
        twoSites();
        String userId = createAccount("it-console-a-user", SITE_A);
        String userToken = loginApp("it-console-a-user", PASSWORD);

        // 先确认能用
        assertThat(mvc.perform(get("/api/auth/me").header("Authorization", "Bearer " + userToken))
                .andReturn().getResponse().getStatus()).isEqualTo(200);

        String adminToken = loginAdmin(ADMIN_A);
        JsonNode change = okJson(post("/api/console/users/" + userId + "/disable")
                .header("Authorization", "Bearer " + adminToken)
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"reason\":\"刷屏\"}"));

        assertThat(change.get("status").asText()).isEqualTo("disabled");
        assertThat(change.get("revoked_sessions").asInt()).isGreaterThanOrEqualTo(1);
        // 站主必须看到这句话，而不是靠文档
        assertThat(change.get("note").asText()).contains("网站账号不受影响");

        // 1) 已登录的令牌当场失效
        assertThat(mvc.perform(get("/api/auth/me").header("Authorization", "Bearer " + userToken))
                .andReturn().getResponse().getStatus()).isEqualTo(401);

        // 2) 用正确密码再登录：403 USER_DISABLED（不是笼统的 401）
        MvcResult relogin = mvc.perform(post("/api/auth/login")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(loginBody("it-console-a-user", PASSWORD)))
                .andReturn();
        assertThat(relogin.getResponse().getStatus()).isEqualTo(403);
        assertThat(errorCode(relogin)).isEqualTo("USER_DISABLED");
    }

    @Test
    @DisplayName("禁用是幂等的：再点一次不报错，也不再撤会话")
    void disableIsIdempotent() throws Exception {
        twoSites();
        String userId = createAccount("it-console-a-user", SITE_A);
        String adminToken = loginAdmin(ADMIN_A);

        okJson(post("/api/console/users/" + userId + "/disable").header("Authorization", "Bearer " + adminToken));
        JsonNode second = okJson(post("/api/console/users/" + userId + "/disable")
                .header("Authorization", "Bearer " + adminToken));

        assertThat(second.get("status").asText()).isEqualTo("disabled");
        assertThat(second.get("revoked_sessions").asInt()).isZero();
    }

    @Test
    @DisplayName("解禁后可以重新登录；解禁不会恢复旧会话")
    void enableAllowsLoginAgain() throws Exception {
        twoSites();
        String userId = createAccount("it-console-a-user", SITE_A);
        String userToken = loginApp("it-console-a-user", PASSWORD);
        String adminToken = loginAdmin(ADMIN_A);

        okJson(post("/api/console/users/" + userId + "/disable").header("Authorization", "Bearer " + adminToken));
        okJson(post("/api/console/users/" + userId + "/enable").header("Authorization", "Bearer " + adminToken));

        assertThat(loginApp("it-console-a-user", PASSWORD)).isNotBlank();
        assertThat(mvc.perform(get("/api/auth/me").header("Authorization", "Bearer " + userToken))
                .andReturn().getResponse().getStatus()).isEqualTo(401);
    }

    // ------------------------------------------------------------------ 鉴权

    @Test
    @DisplayName("不带令牌 401；密码错 401（不区分账号不存在，避免枚举）")
    void authGuards() throws Exception {
        twoSites();

        assertThat(mvc.perform(get("/api/console/overview")).andReturn().getResponse().getStatus())
                .isEqualTo(401);

        MvcResult wrongPassword = mvc.perform(post("/api/console/auth/login")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(loginBody(ADMIN_A, "wrong-password")))
                .andReturn();
        assertThat(wrongPassword.getResponse().getStatus()).isEqualTo(401);
        assertThat(errorCode(wrongPassword)).isEqualTo("INVALID_CREDENTIALS");

        MvcResult unknownUser = mvc.perform(post("/api/console/auth/login")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(loginBody("it-console-nobody", "whatever-123")))
                .andReturn();
        assertThat(unknownUser.getResponse().getStatus()).isEqualTo(401);
    }

    @Test
    @DisplayName("站主令牌与客户端令牌互不通用")
    void tokensAreNotInterchangeable() throws Exception {
        twoSites();
        String userId = createAccount("it-console-a-user", SITE_A);
        String adminToken = loginAdmin(ADMIN_A);
        String userToken = loginApp("it-console-a-user", PASSWORD);

        // 客户端令牌进不了后台
        assertThat(mvc.perform(get("/api/console/overview").header("Authorization", "Bearer " + userToken))
                .andReturn().getResponse().getStatus()).isEqualTo(401);
        // 站主令牌也调不了客户端接口
        assertThat(mvc.perform(get("/api/auth/me").header("Authorization", "Bearer " + adminToken))
                .andReturn().getResponse().getStatus()).isEqualTo(401);
        assertThat(userId).isNotBlank();
    }

    // ------------------------------------------------------------------ 夹具

    private void twoSites() throws Exception {
        createSite(SITE_A, "测试站 A", SRC_A);
        createSite(SITE_B, "测试站 B", SRC_B);
        createAdmin(SITE_A, ADMIN_A);
        createAdmin(SITE_B, ADMIN_B);
    }

    private void createSite(String siteKey, String name, String source) throws Exception {
        mvc.perform(post("/internal/sites")
                        .header("X-Internal-Token", INTERNAL_TOKEN)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"site_key\":\"" + siteKey + "\",\"display_name\":\"" + name
                                + "\",\"sources\":[\"" + source + "\"]}"))
                .andReturn().getResponse().getStatus();
    }

    private void createAdmin(String siteKey, String username) throws Exception {
        MvcResult result = mvc.perform(post("/internal/site-admins")
                        .header("X-Internal-Token", INTERNAL_TOKEN)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"site_key\":\"" + siteKey + "\",\"username\":\"" + username
                                + "\",\"password\":\"" + PASSWORD + "\"}"))
                .andReturn();
        assertThat(result.getResponse().getStatus())
                .as("开设站主失败：%s", result.getResponse().getContentAsString(StandardCharsets.UTF_8))
                .isEqualTo(201);
    }

    private String createAccount(String username, String siteKey) throws Exception {
        String body = siteKey == null
                ? "{\"username\":\"" + username + "\",\"password\":\"" + PASSWORD + "\"}"
                : "{\"username\":\"" + username + "\",\"password\":\"" + PASSWORD
                + "\",\"site_key\":\"" + siteKey + "\"}";
        MvcResult result = mvc.perform(post("/internal/accounts")
                        .header("X-Internal-Token", INTERNAL_TOKEN)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(body))
                .andReturn();
        assertThat(result.getResponse().getStatus())
                .as("建号失败：%s", result.getResponse().getContentAsString(StandardCharsets.UTF_8))
                .isEqualTo(201);
        return json(result).get("user_id").asText();
    }

    private String loginAdmin(String username) throws Exception {
        MvcResult result = mvc.perform(post("/api/console/auth/login")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(loginBody(username, PASSWORD)))
                .andReturn();
        assertThat(result.getResponse().getStatus()).isEqualTo(200);
        return json(result).get("token").asText();
    }

    private String loginApp(String username, String password) throws Exception {
        MvcResult result = mvc.perform(post("/api/auth/login")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(loginBody(username, password)))
                .andReturn();
        assertThat(result.getResponse().getStatus()).isEqualTo(200);
        return json(result).get("token").asText();
    }

    private static String loginBody(String username, String password) {
        return "{\"username\":\"" + username + "\",\"password\":\"" + password + "\"}";
    }

    private JsonNode okJson(MockHttpServletRequestBuilder request) throws Exception {
        request.contentType(MediaType.APPLICATION_JSON);
        MvcResult result = mvc.perform(request).andReturn();
        assertThat(result.getResponse().getStatus())
                .as("期望 200，实际 %s：%s", result.getResponse().getStatus(),
                        result.getResponse().getContentAsString(StandardCharsets.UTF_8))
                .isEqualTo(200);
        return json(result);
    }

    private JsonNode json(MvcResult result) throws Exception {
        return objectMapper.readTree(result.getResponse().getContentAsString(StandardCharsets.UTF_8));
    }

    private String errorCode(MvcResult result) throws Exception {
        return json(result).get("error").get("code").asText();
    }

    private String userStatus(String userId) {
        return jdbc.queryForObject("SELECT status FROM app_user WHERE user_id = ?", String.class, userId);
    }

    private void insertWork(String source, String sourceId, String title) {
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        jdbc.update("""
                        INSERT INTO work (work_id, work_type, title, source, source_id, created_at, updated_at)
                        VALUES (?, 'anime', ?, ?, ?, ?, ?)
                        """,
                "W-" + sourceId, title, source, sourceId, now, now);
    }

    /** 造一条已完成（或未完成）的导入运行。{@code finishedMinutesAgo < 0} 表示没有收尾时间。 */
    private void insertBatchRun(String batchId, String source, int inserted, int rejected,
                                LocalDateTime finishedAt) {
        LocalDateTime started = finishedAt == null
                ? LocalDateTime.now(ZoneOffset.UTC).minusMinutes(5)
                : finishedAt.minusMinutes(1);
        jdbc.update("""
                        INSERT INTO import_batch (batch_id, source, request_hash, inserted, updated,
                                                  unchanged, rejected, run_count, last_run_at,
                                                  started_at, finished_at)
                        VALUES (?, ?, ?, ?, 0, 0, ?, 1, ?, ?, ?)
                        """,
                batchId, source, "0".repeat(64), inserted, rejected, finishedAt, started, finishedAt);
        jdbc.update("""
                        INSERT INTO import_batch_run (batch_id, run_seq, inserted, updated, unchanged,
                                                      rejected, started_at, finished_at)
                        VALUES (?, 1, ?, 0, 0, ?, ?, ?)
                        """,
                batchId, inserted, rejected, started, finishedAt);
    }

    private static LocalDateTime finishedMinutesAgo(int minutes) {
        return LocalDateTime.now(ZoneOffset.UTC).minusMinutes(minutes);
    }
}
