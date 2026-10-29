package com.otaku.ugc;

import com.otaku.common.ApiException;
import com.otaku.common.PageResponse;
import com.otaku.importer.ImportService;
import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchRequest.ImportItem;
import com.otaku.ugc.dto.UgcCommentDto;
import com.otaku.ugc.dto.UgcCommentRequest;
import com.otaku.user.UserRecord;
import com.otaku.work.WorkRecord;
import com.otaku.work.WorkRepository;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.support.GeneratedKeyHolder;
import org.springframework.jdbc.support.KeyHolder;
import org.springframework.test.context.ActiveProfiles;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * 平台代存 UGC · 评论（#240 B1）在真 MySQL 上的行为。
 *
 * <p>为什么必须连真库：验的是「站点隔离 + 状态机 + 软删可见性」这条链路——
 * 用 Mock 只能证明调用了哪几个方法，证明不了「B 站的用户发不进 A 站的作品」
 * 和「删掉的评论真的不再出现在列表里」。
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class UgcIntegrationTest {

    private static final String SITE = "it-ugc-site";
    private static final String OTHER_SITE = "it-ugc-other";
    private static final String SOURCE = "it-ugc-src";
    private static final String BATCH_PREFIX = "it-ugc-batch-";

    @Autowired
    private UgcService service;

    @Autowired
    private ImportService importService;

    @Autowired
    private WorkRepository workRepository;

    @Autowired
    private JdbcTemplate jdbc;

    private UserRecord alice;
    private UserRecord bob;
    private UserRecord outsider;
    private String workId;

    @BeforeEach
    void setUp() {
        cleanUp();
        jdbc.update("INSERT IGNORE INTO site (site_key, display_name, status, created_at, updated_at)"
                + " VALUES (?, 'UGC 测试站', 'active', NOW(3), NOW(3))", SITE);
        jdbc.update("INSERT IGNORE INTO site (site_key, display_name, status, created_at, updated_at)"
                + " VALUES (?, '别的站', 'active', NOW(3), NOW(3))", OTHER_SITE);
        jdbc.update("INSERT IGNORE INTO site_source (site_key, source, created_at) VALUES (?, ?, NOW(3))",
                SITE, SOURCE);

        alice = createUser("it-ugc-alice", SITE);
        bob = createUser("it-ugc-bob", SITE);
        outsider = createUser("it-ugc-carol", OTHER_SITE);

        importService.importBatch(new ImportBatchRequest(
                BATCH_PREFIX + "1", SOURCE, null,
                List.of(new ImportItem("ugc-work-1", "anime", "评论用例作品", null, null, null,
                        List.of(), null, null, null, null, null, null, null, null, null))));
        WorkRecord work = workRepository.findBySourceKey(SOURCE, "ugc-work-1").orElseThrow();
        workId = work.workId();
    }

    @AfterEach
    void cleanUp() {
        jdbc.update("DELETE FROM ugc_comment WHERE site_key IN (?, ?)", SITE, OTHER_SITE);
        jdbc.update("DELETE FROM import_batch_run WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM import_batch WHERE batch_id LIKE ?", BATCH_PREFIX + "%");
        jdbc.update("DELETE FROM work WHERE source = ?", SOURCE);
        jdbc.update("DELETE FROM app_user WHERE user_id LIKE 'it-ugc-%'");
        jdbc.update("DELETE FROM site_source WHERE source = ?", SOURCE);
        jdbc.update("DELETE FROM site WHERE site_key IN (?, ?)", SITE, OTHER_SITE);
    }

    @Test
    @DisplayName("发评论后能读到：最新在前、作者显示用户名、未登录也能读")
    void createThenList() {
        service.create(alice, new UgcCommentRequest(workId, "第一条"));
        service.create(alice, new UgcCommentRequest(workId, "第二条"));

        PageResponse<UgcCommentDto> page = service.list(workId, 1, 20);

        assertThat(page.total()).isEqualTo(2);
        assertThat(page.items()).extracting(UgcCommentDto::body)
                .as("最新在前：第二条应排在第一").containsExactly("第二条", "第一条");
        assertThat(page.items().get(0).author()).isEqualTo("it-ugc-alice");
        assertThat(page.items().get(0).workId()).isEqualTo(workId);
    }

    @Test
    @DisplayName("只能删自己的：删别人的 403，且对方评论仍在")
    void cannotDeleteOthersComment() {
        UgcCommentDto comment = service.create(alice, new UgcCommentRequest(workId, "别人的评论"));

        assertThatThrownBy(() -> service.deleteOwn(bob, comment.commentId()))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("只能删除自己的评论");
        assertThat(service.list(workId, 1, 20).total()).isEqualTo(1);
    }

    @Test
    @DisplayName("删自己的评论：列表立刻消失，重复删不报错（幂等）")
    void deleteOwnIsIdempotent() {
        UgcCommentDto comment = service.create(alice, new UgcCommentRequest(workId, "待删"));
        assertThat(service.list(workId, 1, 20).total()).isEqualTo(1);

        service.deleteOwn(alice, comment.commentId());
        assertThat(service.list(workId, 1, 20).total()).as("软删后不能再出现在列表里").isZero();

        // 再删一次、删一个根本不存在的 id：都是幂等成功，不抛错
        service.deleteOwn(alice, comment.commentId());
        service.deleteOwn(alice, "99999999");
    }

    @Test
    @DisplayName("站点隔离：别的站的用户发不进本站作品，403 而不是 404（说清楚是越权）")
    void crossSiteUserIsRejected() {
        assertThatThrownBy(() -> service.create(outsider, new UgcCommentRequest(workId, "越权发言")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("不属于当前站点");
        assertThat(service.list(workId, 1, 20).total()).isZero();
    }

    @Test
    @DisplayName("内容校验：空白与超长都拒，不截断")
    void rejectsBlankAndOversizedBody() {
        assertThatThrownBy(() -> service.create(alice, new UgcCommentRequest(workId, "   ")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("不能为空");

        String tooLong = "字".repeat(UgcService.MAX_BODY_LENGTH + 1);
        assertThatThrownBy(() -> service.create(alice, new UgcCommentRequest(workId, tooLong)))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("最多");
        assertThat(service.list(workId, 1, 20).total()).isZero();
    }

    @Test
    @DisplayName("防刷屏：同一用户 60 秒内第 6 条被 429 挡住")
    void rateLimitsBurst() {
        for (int i = 1; i <= UgcService.RATE_LIMIT; i++) {
            service.create(alice, new UgcCommentRequest(workId, "刷屏 " + i));
        }

        assertThatThrownBy(() -> service.create(alice, new UgcCommentRequest(workId, "第 6 条")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("发言太快");

        // 换个用户不受影响（限流是按用户的，不是全局）
        service.create(bob, new UgcCommentRequest(workId, "别人不受影响"));
        assertThat(service.list(workId, 1, 20).total()).isEqualTo(UgcService.RATE_LIMIT + 1);
    }

    // ---- 辅助 ----

    private UserRecord createUser(String username, String siteKey) {
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        KeyHolder keyHolder = new GeneratedKeyHolder();
        jdbc.update(con -> {
            var ps = con.prepareStatement("""
                    INSERT INTO app_user (user_id, username, password_hash, site_key, status, created_at, updated_at)
                    VALUES (?, ?, 'x', ?, 'active', ?, ?)
                    """, new String[]{"id"});
            ps.setString(1, username + "-id");
            ps.setString(2, username);
            ps.setString(3, siteKey);
            ps.setObject(4, now);
            ps.setObject(5, now);
            return ps;
        }, keyHolder);
        long id = keyHolder.getKey().longValue();
        return new UserRecord(id, username + "-id", username, "x", siteKey, "active", null, now, now);
    }
}
