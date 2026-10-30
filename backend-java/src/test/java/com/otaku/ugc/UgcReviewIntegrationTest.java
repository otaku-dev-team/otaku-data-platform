package com.otaku.ugc;

import com.otaku.auth.AuthService;
import com.otaku.common.ApiException;
import com.otaku.common.PageResponse;
import com.otaku.importer.ImportService;
import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchRequest.ImportItem;
import com.otaku.ugc.dto.UgcReviewDto;
import com.otaku.ugc.dto.UgcReviewEditRequest;
import com.otaku.ugc.dto.UgcReviewRequest;
import com.otaku.ugc.dto.UgcReviewSummary;
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
 * 平台代存 UGC · 点评（#240 B2c⑥）在真 MySQL 上的行为。
 *
 * <p>为什么必须连真库：验的是「一人一条唯一键 + 均分只算打了分的 + 发布策略可见性」这条链路。
 * 用 Mock 只能证明调了哪个方法，证明不了并发下的唯一键、也证明不了 pending 的点评
 * 真的不进 both 列表和概览。
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class UgcReviewIntegrationTest {

    private static final String SITE = "it-review-site";
    private static final String OTHER_SITE = "it-review-other";
    private static final String SOURCE = "it-review-src";
    private static final String BATCH = "it-review-batch-1";

    @Autowired
    private UgcReviewService service;

    @Autowired
    private AuthService authService;

    @Autowired
    private UgcSettingsRepository settings;

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
                + " VALUES (?, '点评测试站', 'active', NOW(3), NOW(3))", SITE);
        jdbc.update("INSERT IGNORE INTO site (site_key, display_name, status, created_at, updated_at)"
                + " VALUES (?, '别的站', 'active', NOW(3), NOW(3))", OTHER_SITE);
        jdbc.update("INSERT IGNORE INTO site_source (site_key, source, created_at) VALUES (?, ?, NOW(3))",
                SITE, SOURCE);
        jdbc.update("UPDATE site SET ugc_enabled = 1, ugc_moderation = 'post' WHERE site_key = ?", SITE);

        alice = createUser("it-review-alice", SITE);
        bob = createUser("it-review-bob", SITE);
        outsider = createUser("it-review-carol", OTHER_SITE);

        importService.importBatch(new ImportBatchRequest(
                BATCH, SOURCE, null,
                List.of(new ImportItem("review-work-1", "anime", "点评用例作品", null, null, null,
                        List.of(), null, null, null, null, null, null, null, null, null))));
        WorkRecord work = workRepository.findBySourceKey(SOURCE, "review-work-1").orElseThrow();
        workId = work.workId();
    }

    @AfterEach
    void cleanUp() {
        jdbc.update("DELETE FROM ugc_review WHERE site_key IN (?, ?)", SITE, OTHER_SITE);
        jdbc.update("DELETE FROM import_batch_run WHERE batch_id LIKE ?", BATCH + "%");
        jdbc.update("DELETE FROM import_batch WHERE batch_id LIKE ?", BATCH + "%");
        jdbc.update("DELETE FROM work WHERE source = ?", SOURCE);
        jdbc.update("DELETE FROM app_user WHERE user_id LIKE 'it-review-%'");
        jdbc.update("DELETE FROM site_source WHERE source = ?", SOURCE);
        jdbc.update("DELETE FROM site WHERE site_key IN (?, ?)", SITE, OTHER_SITE);
    }

    @Test
    @DisplayName("只打分不写评：可以；body 归一成 null")
    void ratingOnly() {
        UgcReviewDto review = service.create(alice, new UgcReviewRequest(workId, 8, null));

        assertThat(review.rating()).isEqualTo(8);
        assertThat(review.body()).isNull();
        assertThat(review.author()).isEqualTo("it-review-alice");
        assertThat(review.status()).isEqualTo("published");
    }

    @Test
    @DisplayName("只写评不打分：可以；rating 为 null")
    void bodyOnly() {
        UgcReviewDto review = service.create(alice,
                new UgcReviewRequest(workId, null, "  只有文字没有分数  "));

        assertThat(review.rating()).isNull();
        assertThat(review.body()).isEqualTo("只有文字没有分数");
    }

    @Test
    @DisplayName("两样都空 / 评分越界 / 正文超长：都是 400，不截断")
    void rejectsInvalid() {
        assertThatThrownBy(() -> service.create(alice, new UgcReviewRequest(workId, null, "  ")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("至少要打分或写点评内容");

        assertThatThrownBy(() -> service.create(alice, new UgcReviewRequest(workId, 0, "x")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("评分必须在");
        assertThatThrownBy(() -> service.create(alice, new UgcReviewRequest(workId, 11, "x")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("评分必须在");

        String tooLong = "字".repeat(UgcReviewService.MAX_BODY_LENGTH + 1);
        assertThatThrownBy(() -> service.create(alice, new UgcReviewRequest(workId, 5, tooLong)))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("最多");
    }

    @Test
    @DisplayName("一人一条：同一作品第二次提交 409")
    void oneReviewPerWork() {
        service.create(alice, new UgcReviewRequest(workId, 8, null));

        assertThatThrownBy(() -> service.create(alice, new UgcReviewRequest(workId, 9, "想改")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("已经点评过");
    }

    @Test
    @DisplayName("概览：total 含只写文字的，均分只算打了分的，分布按分数聚合")
    void summaryIgnoresUnratedForAverage() {
        service.create(alice, new UgcReviewRequest(workId, 8, null));
        service.create(bob, new UgcReviewRequest(workId, 6, "只打分"));
        // 第三条：只写文字不打分 —— 不能把均分拉成 (8+6+0)/3
        UserRecord carol = createUser("it-review-dave", SITE);
        service.create(carol, new UgcReviewRequest(workId, null, "只写文字"));

        UgcReviewSummary summary = service.summary(workId);

        assertThat(summary.total()).isEqualTo(3);
        assertThat(summary.rated()).isEqualTo(2);
        assertThat(summary.average()).isEqualTo(7.0);
        assertThat(summary.distribution()).extracting(UgcReviewSummary.Bucket::rating)
                .containsExactly(6, 8);
        assertThat(summary.distribution()).extracting(UgcReviewSummary.Bucket::count)
                .containsExactly(1, 1);
    }

    @Test
    @DisplayName("先审后发：点评落 pending，列表与概览都看不到")
    void pendingReviewIsInvisible() {
        jdbc.update("UPDATE site SET ugc_moderation = 'pre' WHERE site_key = ?", SITE);

        UgcReviewDto review = service.create(alice, new UgcReviewRequest(workId, 9, "待审的点评"));
        assertThat(review.status()).isEqualTo("pending");

        assertThat(service.list(workId, 1, 20).total()).isZero();
        assertThat(service.summary(workId).total()).isZero();
        assertThat(service.summary(workId).average()).isNull();
    }

    @Test
    @DisplayName("编辑：省略的字段沿用原值——只改评分时正文不会被清空")
    void editKeepsOmittedField() {
        UgcReviewDto review = service.create(alice, new UgcReviewRequest(workId, 7, "原来的正文"));

        UgcReviewDto edited = service.edit(alice, review.reviewId(),
                new UgcReviewEditRequest(9, null));

        assertThat(edited.rating()).isEqualTo(9);
        assertThat(edited.body()).as("没传 body 不等于清空 body").isEqualTo("原来的正文");
        assertThat(edited.editedAt()).isNotNull();
    }

    @Test
    @DisplayName("编辑别人的点评：403")
    void cannotEditOthers() {
        UgcReviewDto review = service.create(alice, new UgcReviewRequest(workId, 7, "原文"));

        assertThatThrownBy(() -> service.edit(bob, review.reviewId(),
                new UgcReviewEditRequest(1, "改掉")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("只能修改自己的点评");
    }

    @Test
    @DisplayName("删除：软删保行、列表消失、重复删幂等；别人的 403")
    void deleteIsSoftAndIdempotent() {
        UgcReviewDto review = service.create(alice, new UgcReviewRequest(workId, 8, "待删"));
        service.create(bob, new UgcReviewRequest(workId, 6, "别人的"));

        service.deleteOwn(alice, review.reviewId());
        assertThat(service.list(workId, 1, 20).total()).isEqualTo(1);

        Integer rows = jdbc.queryForObject(
                "SELECT COUNT(*) FROM ugc_review WHERE site_key = ? AND status = 'deleted'",
                Integer.class, SITE);
        assertThat(rows).as("软删保留行").isEqualTo(1);

        service.deleteOwn(alice, review.reviewId());   // 幂等
        service.deleteOwn(alice, "99999999");          // 不存在也幂等

        UgcReviewDto bobs = service.list(workId, 1, 20).items().get(0);
        assertThatThrownBy(() -> service.deleteOwn(alice, bobs.reviewId()))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("只能删除自己的点评");
    }

    @Test
    @DisplayName("站点隔离：别的站的用户点评不了本站作品（403）")
    void crossSiteIsRejected() {
        assertThatThrownBy(() -> service.create(outsider,
                new UgcReviewRequest(workId, 8, "越权点评")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("不属于当前站点");
    }

    @Test
    @DisplayName("注销用户：点评保留，作者显示「已注销用户」")
    void deletedAuthorIsAnonymized() {
        service.create(alice, new UgcReviewRequest(workId, 8, "注销前的点评"));
        authService.deleteAccount(alice);

        PageResponse<UgcReviewDto> page = service.list(workId, 1, 20);
        assertThat(page.total()).isEqualTo(1);
        assertThat(page.items().get(0).author()).isEqualTo("已注销用户");
        assertThat(page.items().get(0).body()).isEqualTo("注销前的点评");
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
        return new UserRecord(id, username + "-id", username, "x", siteKey, "active", now, now, now);
    }
}
