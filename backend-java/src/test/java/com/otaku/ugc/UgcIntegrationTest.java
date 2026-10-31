package com.otaku.ugc;

import com.otaku.auth.AuthService;
import com.otaku.common.ApiException;
import com.otaku.console.ConsolePrincipal;
import com.otaku.console.dto.ConsoleDtos;
import com.otaku.common.PageResponse;
import com.otaku.importer.ImportService;
import com.otaku.importer.dto.ImportBatchRequest;
import com.otaku.importer.dto.ImportBatchRequest.ImportItem;
import com.otaku.ugc.dto.CommentReportDto;
import com.otaku.ugc.dto.CommentReportRequest;
import com.otaku.ugc.dto.UgcCommentDto;
import com.otaku.ugc.dto.UgcCommentEditRequest;
import com.otaku.ugc.dto.UgcCommentRequest;
import com.otaku.user.AccountDeletedEvent;
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
import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.assertj.core.api.Assertions.catchThrowableOfType;

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
    private ConsoleUgcService consoleUgcService;

    @Autowired
    private UgcReportService reportService;

    @Autowired
    private UgcSettingsRepository settings;

    @Autowired
    private UgcCleanupJob cleanupJob;

    @Autowired
    private AuthService authService;

    @Autowired
    private UgcRepository ugcRepository;

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
        // B2 起写入要求站主先开社区；本类的用例默认在「已开启」下跑，
        // 开关本身的语义由 disabledSiteRejectsWrites / featuresReflectSetting 两条单独覆盖。
        jdbc.update("UPDATE site SET ugc_enabled = 1 WHERE site_key = ?", SITE);

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
        jdbc.update("DELETE FROM console_audit WHERE actor_admin_id LIKE 'it-ugc-%'");
        jdbc.update("DELETE FROM ugc_report WHERE site_key IN (?, ?)", SITE, OTHER_SITE);
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
    @DisplayName("长度按码点算：1000 个 emoji 收得下，1001 个才拒")
    void lengthCountsCodePointsNotUtf16Units() {
        // 修复前：1000 个 emoji 的 String.length() == 2000，会被误判超长
        UgcCommentDto accepted = service.create(alice,
                new UgcCommentRequest(workId, "😀".repeat(UgcService.MAX_BODY_LENGTH)));
        assertThat(com.otaku.common.TextLength.of(accepted.body()))
                .isEqualTo(UgcService.MAX_BODY_LENGTH); // 存下来的仍是 1000 个字，没按字节截断

        assertThatThrownBy(() -> service.create(alice,
                new UgcCommentRequest(workId, "😀".repeat(UgcService.MAX_BODY_LENGTH + 1))))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("最多");
    }

    @Test
    @DisplayName("防刷屏：同一用户 60 秒内第 6 条被 429 挡住")
    void rateLimitsBurst() {
        for (int i = 1; i <= UgcService.RATE_LIMIT; i++) {
            service.create(alice, new UgcCommentRequest(workId, "刷屏 " + i));
        }

        ApiException tooFast = catchThrowableOfType(
                () -> service.create(alice, new UgcCommentRequest(workId, "第 6 条")),
                ApiException.class);
        assertThat(tooFast).hasMessageContaining("发言太快");
        // 契约里 429 声明了 Retry-After，这里钉住「真的会给」且落在窗口内
        assertThat(tooFast.retryAfterSeconds())
                .isNotNull()
                .isBetween(1, UgcService.RATE_WINDOW_SECONDS);

        // 换个用户不受影响（限流是按用户的，不是全局）
        service.create(bob, new UgcCommentRequest(workId, "别人不受影响"));
        assertThat(service.list(workId, 1, 20).total()).isEqualTo(UgcService.RATE_LIMIT + 1);
    }

    @Test
    @DisplayName("站主没开社区：写接口 403，features 返回 false")
    void disabledSiteRejectsWrites() {
        jdbc.update("UPDATE site SET ugc_enabled = 0 WHERE site_key = ?", SITE);

        assertThatThrownBy(() -> service.create(alice, new UgcCommentRequest(workId, "没开也发")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("未开启社区");
        assertThat(service.list(workId, 1, 20).total()).isZero();
    }

    @Test
    @DisplayName("features 端点跟着开关走（单站实例按唯一 active 站点解析）")
    void featuresReflectSetting() {
        jdbc.update("UPDATE site SET status = 'suspended' WHERE site_key = ?", OTHER_SITE);
        assertThat(featuresEnabled()).isTrue();

        consoleUgcService.updateSetting(consoleAdmin(SITE), false, null);
        assertThat(featuresEnabled()).isFalse();
        consoleUgcService.updateSetting(consoleAdmin(SITE), true, null);
        assertThat(featuresEnabled()).isTrue();
    }

    @Test
    @DisplayName("后台审核：看得到、能隐藏、能恢复，且隐藏后客户端列表立刻消失")
    void consoleCanHideAndPublish() {
        UgcCommentDto comment = service.create(alice, new UgcCommentRequest(workId, "待审内容"));
        ConsolePrincipal admin = consoleAdmin(SITE);

        var page = consoleUgcService.list(admin, "published", 1, 20);
        assertThat(page.total()).isEqualTo(1);
        assertThat(page.items().get(0).workTitle()).isEqualTo("评论用例作品");

        ConsoleDtos.UgcItem hidden = consoleUgcService.hide(admin, comment.commentId());
        assertThat(hidden.status()).isEqualTo("hidden");
        assertThat(service.list(workId, 1, 20).total()).as("隐藏后对外不可见").isZero();

        // 幂等：再隐藏一次不报错，状态不变
        assertThat(consoleUgcService.hide(admin, comment.commentId()).status()).isEqualTo("hidden");

        ConsoleDtos.UgcItem back = consoleUgcService.publish(admin, comment.commentId());
        assertThat(back.status()).isEqualTo("published");
        assertThat(service.list(workId, 1, 20).total()).isEqualTo(1);
    }

    @Test
    @DisplayName("后台只动本站：别的站的评论看不到，也隐藏不了（404 而不是悄悄改）")
    void consoleIsIsolatedBySite() {
        UgcCommentDto comment = service.create(alice, new UgcCommentRequest(workId, "本站评论"));
        ConsolePrincipal otherAdmin = consoleAdmin(OTHER_SITE);

        var page = consoleUgcService.list(otherAdmin, null, 1, 20);
        assertThat(page.total()).isZero();
        assertThat(page.items()).as("条目也必须为空，不能只让 total 是 0").isEmpty();
        assertThatThrownBy(() -> consoleUgcService.hide(otherAdmin, comment.commentId()))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("评论不存在");
    }

    @Test
    @DisplayName("开关变更写审计：谁在什么时候开/关，必须能查")
    void settingChangeIsAudited() {
        consoleUgcService.updateSetting(consoleAdmin(SITE), false, null);
        Integer audited = jdbc.queryForObject(
                "SELECT COUNT(*) FROM console_audit WHERE action = 'ugc.setting' AND target_id = ?",
                Integer.class, SITE);
        assertThat(audited).isEqualTo(1);
    }

    @Test
    @DisplayName("先审后发：新评论落 pending、对外不可见，站主发布后才出现")
    void preModerationKeepsCommentPending() {
        jdbc.update("UPDATE site SET ugc_moderation = 'pre' WHERE site_key = ?", SITE);

        UgcCommentDto created = service.create(alice, new UgcCommentRequest(workId, "待审核内容"));
        assertThat(created.status()).isEqualTo("pending");
        assertThat(service.list(workId, 1, 20).total()).as("pending 不能出现在公开列表").isZero();

        ConsolePrincipal admin = consoleAdmin(SITE);
        var pending = consoleUgcService.list(admin, "pending", 1, 20);
        assertThat(pending.total()).isEqualTo(1);

        consoleUgcService.publish(admin, created.commentId());
        assertThat(service.list(workId, 1, 20).total()).isEqualTo(1);
    }

    @Test
    @DisplayName("举报：同一人同一评论只有一张工单；采纳后评论被隐藏、驳回则评论不动")
    void reportFlow() {
        UgcCommentDto a = service.create(alice, new UgcCommentRequest(workId, "被举报的评论"));
        UgcCommentDto b = service.create(alice, new UgcCommentRequest(workId, "另一条"));
        ConsolePrincipal admin = consoleAdmin(SITE);

        var first = reportService.report(bob, new CommentReportRequest(a.commentId(), "引战"));
        assertThat(first.created()).isTrue();
        var again = reportService.report(bob, new CommentReportRequest(a.commentId(), "再点一次"));
        assertThat(again.created()).as("重复举报返回原工单，不再建单").isFalse();
        assertThat(again.report().reportId()).isEqualTo(first.report().reportId());

        assertThat(consoleUgcService.listReports(admin, "open", 1, 20).total()).isEqualTo(1);
        consoleUgcService.resolveReport(admin, first.report().reportId());
        assertThat(service.list(workId, 1, 20).total()).as("采纳后该评论被隐藏").isEqualTo(1); // 只剩 b

        var second = reportService.report(bob, new CommentReportRequest(b.commentId(), "也举报"));
        consoleUgcService.dismissReport(admin, second.report().reportId());
        assertThat(service.list(workId, 1, 20).total()).as("驳回不动评论").isEqualTo(1);
    }

    @Test
    @DisplayName("举报自己的评论被拒（有自己的删除入口）")
    void cannotReportOwnComment() {
        UgcCommentDto own = service.create(alice, new UgcCommentRequest(workId, "自己的"));
        assertThatThrownBy(() -> reportService.report(alice, new CommentReportRequest(own.commentId(), "自举报")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("自己的评论");
    }

    @Test
    @DisplayName("导出 CSV：表头齐全、逗号/引号/换行被正确转义、只含本站、回复带 parent_id")
    void exportCsvEscapesAndIsolates() {
        UgcCommentDto floor = service.create(alice, new UgcCommentRequest(workId, "普通,带逗号"));
        service.create(alice, new UgcCommentRequest(workId, "带\"引号\"的内容"));
        service.create(alice, new UgcCommentRequest(workId, "第一行\n第二行"));
        service.create(bob, new UgcCommentRequest(workId, "一条回复", floor.commentId()));
        // 别的站的评论：直接插库（业务入口会拦跨站），只为验证导出不漏本站以外
        jdbc.update("""
                INSERT INTO ugc_comment (site_key, work_id, user_id, body, status, created_at, updated_at)
                VALUES (?, ?, ?, '别的站的内容', 'published', NOW(3), NOW(3))
                """, OTHER_SITE, workId, outsider.id());

        var exported = consoleUgcService.exportCsv(consoleAdmin(SITE), "all");

        assertThat(exported.rows()).isEqualTo(4);
        assertThat(exported.truncated()).isFalse();
        assertThat(exported.csv()).startsWith(
                "comment_id,parent_id,work_id,work_title,author,status,created_at,body");
        assertThat(exported.csv()).contains("\"普通,带逗号\"");
        assertThat(exported.csv()).contains("\"带\"\"引号\"\"的内容\"");
        assertThat(exported.csv()).contains("\"第一行\n第二行\"");
        assertThat(exported.csv()).as("别站的数据不能出现在本站导出里").doesNotContain("别的站的内容");

        String replyLine = java.util.Arrays.stream(exported.csv().split("\r\n"))
                .filter(line -> line.contains("it-ugc-bob"))
                .findFirst().orElseThrow();
        assertThat(replyLine.split(",")[1])
                .as("回复行的 parent_id 应指向主评论").isEqualTo(floor.commentId());
    }

    @Test
    @DisplayName("导出写审计：谁在什么时候导了多少条")
    void exportIsAudited() {
        service.create(alice, new UgcCommentRequest(workId, "导出审计"));
        consoleUgcService.exportCsv(consoleAdmin(SITE), "all");

        Integer audited = jdbc.queryForObject(
                "SELECT COUNT(*) FROM console_audit WHERE action = 'ugc.export' AND target_id = ?",
                Integer.class, SITE);
        assertThat(audited).isEqualTo(1);
    }

    // ---- 回复（B2c②）：只允许一层 ----

    @Test
    @DisplayName("回复挂在顶层下：total 只算顶层，回复按最早在前内嵌")
    void repliesAreNestedUnderFloor() {
        UgcCommentDto floor = service.create(alice, new UgcCommentRequest(workId, "主评论"));
        service.create(bob, new UgcCommentRequest(workId, "第一回复", floor.commentId()));
        service.create(bob, new UgcCommentRequest(workId, "第二回复", floor.commentId()));

        PageResponse<UgcCommentDto> page = service.list(workId, 1, 20);

        assertThat(page.total()).as("回复不计入顶层 total").isEqualTo(1);
        UgcCommentDto got = page.items().get(0);
        assertThat(got.replyCount()).isEqualTo(2);
        assertThat(got.replies()).extracting(UgcCommentDto::body)
                .as("对话顺序：最早在前").containsExactly("第一回复", "第二回复");
        assertThat(got.replies()).allSatisfy(r ->
                assertThat(r.parentId()).isEqualTo(floor.commentId()));
        assertThat(got.parentId()).as("顶层评论没有父").isNull();
    }

    @Test
    @DisplayName("回复预览最多 3 条，reply_count 仍是全量")
    void replyPreviewIsCappedButCountIsNot() {
        UgcCommentDto floor = service.create(alice, new UgcCommentRequest(workId, "主评论"));
        for (int i = 1; i <= 4; i++) {
            service.create(alice, new UgcCommentRequest(workId, "回复 " + i, floor.commentId()));
        }

        UgcCommentDto got = service.list(workId, 1, 20).items().get(0);
        assertThat(got.replyCount()).isEqualTo(4);
        assertThat(got.replies()).as("内嵌只给前 3 条，剩下的走 replies 端点").hasSize(3);
        assertThat(got.replies()).extracting(UgcCommentDto::body)
                .containsExactly("回复 1", "回复 2", "回复 3");
    }

    @Test
    @DisplayName("replies 端点：按对话顺序分页，total 是该楼的回复数")
    void repliesEndpointPaginatesInConversationOrder() {
        UgcCommentDto floor = service.create(alice, new UgcCommentRequest(workId, "主评论"));
        for (int i = 1; i <= 5; i++) {
            service.create(bob, new UgcCommentRequest(workId, "回复 " + i, floor.commentId()));
        }

        PageResponse<UgcCommentDto> first = service.listReplies(workId, floor.commentId(), 1, 3);
        assertThat(first.total()).isEqualTo(5);
        assertThat(first.items()).extracting(UgcCommentDto::body)
                .containsExactly("回复 1", "回复 2", "回复 3");

        PageResponse<UgcCommentDto> second = service.listReplies(workId, floor.commentId(), 2, 3);
        assertThat(second.items()).extracting(UgcCommentDto::body)
                .containsExactly("回复 4", "回复 5");
    }

    @Test
    @DisplayName("只支持一层：回复一条回复直接 400，说清楚是用法错误")
    void cannotReplyToReply() {
        UgcCommentDto floor = service.create(alice, new UgcCommentRequest(workId, "主评论"));
        UgcCommentDto reply = service.create(bob,
                new UgcCommentRequest(workId, "一条回复", floor.commentId()));

        assertThatThrownBy(() -> service.create(alice,
                new UgcCommentRequest(workId, "回复的回复", reply.commentId())))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("只支持回复主评论");
    }

    @Test
    @DisplayName("回复别的作品的评论：404，不泄露那条评论存不存在")
    void cannotReplyAcrossWorks() {
        importService.importBatch(new ImportBatchRequest(
                BATCH_PREFIX + "2", SOURCE, null,
                List.of(new ImportItem("ugc-work-2", "anime", "另一部作品", null, null, null,
                        List.of(), null, null, null, null, null, null, null, null, null))));
        String otherWork = workRepository.findBySourceKey(SOURCE, "ugc-work-2").orElseThrow().workId();
        UgcCommentDto elsewhere = service.create(alice,
                new UgcCommentRequest(otherWork, "别处的评论"));

        assertThatThrownBy(() -> service.create(alice,
                new UgcCommentRequest(workId, "跨作品回复", elsewhere.commentId())))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("不存在");
    }

    @Test
    @DisplayName("回复被隐藏的评论：404（那条楼已经不在公开列表里，不能往上挂）")
    void cannotReplyToHiddenFloor() {
        UgcCommentDto floor = service.create(alice, new UgcCommentRequest(workId, "会被隐藏"));
        consoleUgcService.hide(consoleAdmin(SITE), floor.commentId());

        assertThatThrownBy(() -> service.create(bob,
                new UgcCommentRequest(workId, "回复隐藏楼", floor.commentId())))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("不存在");
    }

    @Test
    @DisplayName("先审后发：回复落 pending，公开列表看不到，reply_count 也不计")
    void pendingReplyIsInvisible() {
        UgcCommentDto floor = service.create(alice, new UgcCommentRequest(workId, "主评论"));
        jdbc.update("UPDATE site SET ugc_moderation = 'pre' WHERE site_key = ?", SITE);

        UgcCommentDto reply = service.create(bob,
                new UgcCommentRequest(workId, "待审回复", floor.commentId()));
        assertThat(reply.status()).isEqualTo("pending");

        UgcCommentDto got = service.list(workId, 1, 20).items().get(0);
        assertThat(got.replyCount()).isZero();
        assertThat(got.replies()).isEmpty();
        assertThat(service.listReplies(workId, floor.commentId(), 1, 20).total()).isZero();
    }

    @Test
    @DisplayName("撤回楼层：顶层评论连同回复一起软删，行还在（可追溯）")
    void deletingFloorCascadesToReplies() {
        UgcCommentDto floor = service.create(alice, new UgcCommentRequest(workId, "主评论"));
        service.create(bob, new UgcCommentRequest(workId, "回复一", floor.commentId()));
        service.create(bob, new UgcCommentRequest(workId, "回复二", floor.commentId()));

        service.deleteOwn(alice, floor.commentId());

        assertThat(service.list(workId, 1, 20).total()).isZero();
        Integer rows = jdbc.queryForObject(
                "SELECT COUNT(*) FROM ugc_comment WHERE site_key = ? AND status = 'deleted'",
                Integer.class, SITE);
        assertThat(rows).as("三层都软删，但行保留").isEqualTo(3);
    }

    @Test
    @DisplayName("删一条回复只影响自己：主评论仍在，另一条回复仍在")
    void deletingReplyDoesNotTouchFloor() {
        UgcCommentDto floor = service.create(alice, new UgcCommentRequest(workId, "主评论"));
        UgcCommentDto first = service.create(bob,
                new UgcCommentRequest(workId, "回复一", floor.commentId()));
        service.create(bob, new UgcCommentRequest(workId, "回复二", floor.commentId()));

        service.deleteOwn(bob, first.commentId());

        PageResponse<UgcCommentDto> page = service.list(workId, 1, 20);
        assertThat(page.total()).isEqualTo(1);
        assertThat(page.items().get(0).replyCount()).isEqualTo(1);
        assertThat(page.items().get(0).replies()).extracting(UgcCommentDto::body)
                .containsExactly("回复二");
    }

    @Test
    @DisplayName("回复与顶层共用限流额度，不能靠回复绕过")
    void repliesShareRateLimit() {
        UgcCommentDto floor = service.create(alice, new UgcCommentRequest(workId, "主评论"));
        for (int i = 2; i <= UgcService.RATE_LIMIT; i++) {
            service.create(alice, new UgcCommentRequest(workId, "刷 " + i, floor.commentId()));
        }

        assertThatThrownBy(() -> service.create(alice,
                new UgcCommentRequest(workId, "第 6 条", floor.commentId())))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("发言太快");
    }

    @Test
    @DisplayName("编辑评论：正文更新、edited_at 有值、状态保持 published")
    void editOwnUpdatesBodyAndStamp() {
        UgcCommentDto comment = service.create(alice, new UgcCommentRequest(workId, "错别字"));

        UgcCommentDto edited = service.editOwn(alice, comment.commentId(),
                new UgcCommentEditRequest("改好了"));

        assertThat(edited.body()).isEqualTo("改好了");
        assertThat(edited.editedAt()).isNotNull();
        assertThat(edited.status()).isEqualTo("published");
        assertThat(service.list(workId, 1, 20).items().get(0).body()).isEqualTo("改好了");
    }

    @Test
    @DisplayName("只能改自己的：别人的 403，内容一个字都不动")
    void cannotEditOthersComment() {
        UgcCommentDto comment = service.create(alice, new UgcCommentRequest(workId, "原文"));

        assertThatThrownBy(() -> service.editOwn(bob, comment.commentId(),
                new UgcCommentEditRequest("篡改")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("只能修改自己的评论");
        assertThat(service.list(workId, 1, 20).items().get(0).body()).isEqualTo("原文");
    }

    @Test
    @DisplayName("已撤回 / 被站主隐藏的评论不能再编辑：404，不泄露「其实还在」")
    void cannotEditDeletedOrHidden() {
        UgcCommentDto deleted = service.create(alice, new UgcCommentRequest(workId, "要删的"));
        service.deleteOwn(alice, deleted.commentId());
        assertThatThrownBy(() -> service.editOwn(alice, deleted.commentId(),
                new UgcCommentEditRequest("改已删的")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("评论不存在");

        UgcCommentDto hidden = service.create(alice, new UgcCommentRequest(workId, "会被隐藏"));
        consoleUgcService.hide(consoleAdmin(SITE), hidden.commentId());
        assertThatThrownBy(() -> service.editOwn(alice, hidden.commentId(),
                new UgcCommentEditRequest("改被藏的")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("评论不存在");
    }

    @Test
    @DisplayName("编辑也要过内容校验：空白与超长都拒，不截断")
    void editValidatesBody() {
        UgcCommentDto comment = service.create(alice, new UgcCommentRequest(workId, "原文"));

        assertThatThrownBy(() -> service.editOwn(alice, comment.commentId(),
                new UgcCommentEditRequest("   ")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("不能为空");

        assertThatThrownBy(() -> service.editOwn(alice, comment.commentId(),
                new UgcCommentEditRequest("字".repeat(UgcService.MAX_BODY_LENGTH + 1))))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("最多");
    }

    @Test
    @DisplayName("先审后发：编辑后重新落回 pending，公开列表立刻看不到")
    void editInPreModeGoesBackToPending() {
        UgcCommentDto comment = service.create(alice, new UgcCommentRequest(workId, "先发后审的评论"));
        assertThat(service.list(workId, 1, 20).total()).isEqualTo(1);

        jdbc.update("UPDATE site SET ugc_moderation = 'pre' WHERE site_key = ?", SITE);
        UgcCommentDto edited = service.editOwn(alice, comment.commentId(),
                new UgcCommentEditRequest("改成要重审的内容"));

        assertThat(edited.status()).isEqualTo("pending");
        assertThat(service.list(workId, 1, 20).total()).as("待审后公开列表看不到").isZero();
    }

    @Test
    @DisplayName("编辑回复：正文更新，parent_id 不变，不带 reply_count")
    void editReplyKeepsParent() {
        UgcCommentDto floor = service.create(alice, new UgcCommentRequest(workId, "主评论"));
        UgcCommentDto reply = service.create(bob,
                new UgcCommentRequest(workId, "回复原文", floor.commentId()));

        UgcCommentDto edited = service.editOwn(bob, reply.commentId(),
                new UgcCommentEditRequest("回复改过"));

        assertThat(edited.body()).isEqualTo("回复改过");
        assertThat(edited.parentId()).isEqualTo(floor.commentId());
        assertThat(edited.replyCount()).isNull();
    }

    // ---- 注销（B2c⑤）：默认匿名化保留，开关打开才移除 ----

    @Test
    @DisplayName("注销账号：status 置 disabled、deleted_at 有值，评论保留但作者显示「已注销用户」")
    void accountDeletionAnonymizesAuthor() {
        service.create(alice, new UgcCommentRequest(workId, "注销前的评论"));

        authService.deleteAccount(alice);

        Map<String, Object> row = jdbc.queryForMap(
                "SELECT status, deleted_at FROM app_user WHERE id = ?", alice.id());
        assertThat(row.get("status")).isEqualTo("disabled");
        assertThat(row.get("deleted_at")).isNotNull();

        PageResponse<UgcCommentDto> page = service.list(workId, 1, 20);
        assertThat(page.total()).as("评论保留，楼层不塌").isEqualTo(1);
        assertThat(page.items().get(0).author()).isEqualTo("已注销用户");
        assertThat(page.items().get(0).body()).isEqualTo("注销前的评论");
    }

    @Test
    @DisplayName("注销开关打开：该用户评论立即软删（对外消失），行仍保留，别人的不动")
    void accountRemovalSwitchHidesComments() {
        service.create(alice, new UgcCommentRequest(workId, "要被移除的"));
        service.create(bob, new UgcCommentRequest(workId, "别人的留着"));

        // 直接构造强制开启的监听器，不依赖 Spring 里的默认配置
        new AccountDeletionUgcListener(ugcRepository, true)
                .onAccountDeleted(new AccountDeletedEvent(alice.id(), SITE));

        PageResponse<UgcCommentDto> page = service.list(workId, 1, 20);
        assertThat(page.total()).isEqualTo(1);
        assertThat(page.items().get(0).author()).isEqualTo("it-ugc-bob");

        Integer deleted = jdbc.queryForObject(
                "SELECT COUNT(*) FROM ugc_comment WHERE site_key = ? AND user_id = ? AND status = 'deleted'",
                Integer.class, SITE, alice.id());
        assertThat(deleted).as("软删保留行，物理清理由留存作业兜底").isEqualTo(1);
    }

    @Test
    @DisplayName("留存清理：只清超期撤回的评论，其他状态即便更老也不动")
    void cleanupPurgesOnlyExpiredDeleted() {
        UgcCommentDto oldDeleted = service.create(alice, new UgcCommentRequest(workId, "很久以前撤回"));
        UgcCommentDto freshDeleted = service.create(alice, new UgcCommentRequest(workId, "刚撤回"));
        UgcCommentDto published = service.create(alice, new UgcCommentRequest(workId, "还在的"));
        service.deleteOwn(alice, oldDeleted.commentId());
        service.deleteOwn(alice, freshDeleted.commentId());

        // 把「很早撤回的」和「仍然公开的」都改成 200 天前：
        // 后者用来证明清理看的是 status，不只是时间。
        LocalDateTime longAgo = LocalDateTime.now(ZoneOffset.UTC).minusDays(200);
        jdbc.update("UPDATE ugc_comment SET updated_at = ? WHERE id IN (?, ?)", longAgo,
                Long.parseLong(oldDeleted.commentId()), Long.parseLong(published.commentId()));

        int purged = cleanupJob.purge(LocalDateTime.now(ZoneOffset.UTC));

        assertThat(purged).as("只有那条超期的撤回被物理删").isEqualTo(1);
        assertThat(countComment(oldDeleted.commentId())).isZero();
        assertThat(countComment(freshDeleted.commentId())).as("未到保留期，留着").isEqualTo(1);
        assertThat(countComment(published.commentId())).as("published 再老也不清").isEqualTo(1);
    }

    private int countComment(String commentId) {
        Integer n = jdbc.queryForObject("SELECT COUNT(*) FROM ugc_comment WHERE id = ?",
                Integer.class, Long.parseLong(commentId));
        return n == null ? 0 : n;
    }

    private boolean featuresEnabled() {
        // 与 UgcController.features() 同一口径
        return settings.singleActiveSite().map(settings::isEnabled).orElse(false);
    }

    private static ConsolePrincipal consoleAdmin(String siteKey) {
        return new ConsolePrincipal(1L, "it-ugc-admin", "it-ugc-admin", "审核员",
                "platform", siteKey, siteKey);
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
