package com.otaku.ugc;

import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.common.PageResponse;
import com.otaku.console.ConsoleAuditRepository;
import com.otaku.console.ConsolePrincipal;
import com.otaku.console.ConsoleScope;
import com.otaku.console.ConsoleScopeResolver;
import com.otaku.console.dto.ConsoleDtos;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Set;

/**
 * 站主后台的 UGC 审核（#240 B2a）：看列表、隐藏、恢复、开关。
 *
 * <p>站点来自登录主体（{@link ConsolePrincipal}），**不接受请求参数**——与后台其它接口同一红线。
 * 隐藏/恢复都写审计：内容是用户写的，谁在什么时候把它藏了，必须能查。
 */
@Service
public class ConsoleUgcService {

    private static final Logger log = LoggerFactory.getLogger(ConsoleUgcService.class);

    private static final Set<String> FILTERABLE = Set.of("published", "pending", "hidden", "deleted");
    private static final Set<String> REPORT_FILTERABLE = Set.of("open", "resolved", "dismissed");
    private static final Set<String> MODERATION_MODES = Set.of("post", "pre");
    private static final int MAX_PAGE_SIZE = 50;
    /** 导出上限：够覆盖单站现阶段数据量，又不至于一次请求吃穿内存。 */
    private static final int MAX_EXPORT_ROWS = 50_000;

    private final UgcRepository ugcRepository;
    private final UgcReportRepository reportRepository;
    private final UgcSettingsRepository settings;
    private final ConsoleScopeResolver scopeResolver;
    private final ConsoleAuditRepository auditRepository;

    public ConsoleUgcService(UgcRepository ugcRepository, UgcReportRepository reportRepository,
                             UgcSettingsRepository settings, ConsoleScopeResolver scopeResolver,
                             ConsoleAuditRepository auditRepository) {
        this.ugcRepository = ugcRepository;
        this.reportRepository = reportRepository;
        this.settings = settings;
        this.scopeResolver = scopeResolver;
        this.auditRepository = auditRepository;
    }

    public PageResponse<ConsoleDtos.UgcItem> list(ConsolePrincipal principal, String status,
                                                  int page, int pageSize) {
        ConsoleScope scope = scopeResolver.resolve(principal);
        String filter = normalizeFilter(status);
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, pageSize), MAX_PAGE_SIZE);

        long total = ugcRepository.countForConsole(scope.siteKey(), filter);
        List<ConsoleDtos.UgcItem> items = ugcRepository
                .findForConsole(scope.siteKey(), filter, safeSize, (safePage - 1) * safeSize)
                .stream()
                .map(row -> new ConsoleDtos.UgcItem(
                        String.valueOf(row.id()), row.workId(), row.workTitle(), row.username(),
                        row.body(), row.status(),
                        row.createdAt() == null ? null : row.createdAt().toInstant(ZoneOffset.UTC)))
                .toList();
        return PageResponse.of(safePage, safeSize, total, items);
    }

    /** 隐藏一条评论。幂等：已隐藏再点一次不报错，也不重复记审计。 */
    public ConsoleDtos.UgcItem hide(ConsolePrincipal principal, String commentId) {
        return changeStatus(principal, commentId, "hidden",
                ConsoleAuditRepository.ACTION_UGC_HIDE);
    }

    /** 恢复一条被隐藏的评论。 */
    public ConsoleDtos.UgcItem publish(ConsolePrincipal principal, String commentId) {
        return changeStatus(principal, commentId, "published",
                ConsoleAuditRepository.ACTION_UGC_PUBLISH);
    }

    public ConsoleDtos.UgcSetting setting(ConsolePrincipal principal) {
        ConsoleScope scope = scopeResolver.resolve(principal);
        return new ConsoleDtos.UgcSetting(settings.isEnabled(scope.siteKey()),
                settings.moderationMode(scope.siteKey()));
    }

    /**
     * 改开关 / 改发布策略。两者都可单独给，但不能都不给——
     * 「什么都不改」当成成功会让调用方以为自己改成功了。
     */
    public ConsoleDtos.UgcSetting updateSetting(ConsolePrincipal principal, Boolean enabled,
                                               String moderation) {
        if (enabled == null && moderation == null) {
            throw ApiException.badRequest("enabled 与 moderation 至少要给一个");
        }
        String mode = null;
        if (moderation != null) {
            mode = moderation.trim();
            if (!MODERATION_MODES.contains(mode)) {
                throw ApiException.badRequest("moderation 只能是 post 或 pre");
            }
        }
        ConsoleScope scope = scopeResolver.resolve(principal);
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        if (enabled != null) {
            settings.setEnabled(scope.siteKey(), enabled, now);
        }
        if (mode != null) {
            settings.setModerationMode(scope.siteKey(), mode, now);
        }
        String detail = (enabled == null ? "" : (enabled ? "启用社区" : "关闭社区"))
                + (mode == null ? "" : (detailSeparator(enabled) + "审核模式=" + mode));
        auditRepository.record(scope.siteKey(), principal.adminId(),
                ConsoleAuditRepository.ACTION_UGC_SETTING, "site", scope.siteKey(), detail, now);
        log.info("站主 {} 改站点 {} 的 UGC 配置：enabled={} moderation={}",
                principal.adminId(), scope.siteKey(), enabled, mode);
        return setting(principal);
    }

    private static String detailSeparator(Boolean enabled) {
        return enabled == null ? "" : "；";
    }

    // ---- 举报队列 ----

    public PageResponse<ConsoleDtos.ReportItem> listReports(ConsolePrincipal principal, String status,
                                                           int page, int pageSize) {
        ConsoleScope scope = scopeResolver.resolve(principal);
        String filter = normalizeReportFilter(status);
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, pageSize), MAX_PAGE_SIZE);

        long total = reportRepository.countForConsole(scope.siteKey(), filter);
        List<ConsoleDtos.ReportItem> items = reportRepository
                .listForConsole(scope.siteKey(), filter, safeSize, (safePage - 1) * safeSize)
                .stream()
                .map(row -> new ConsoleDtos.ReportItem(
                        String.valueOf(row.id()), String.valueOf(row.commentId()), row.workId(),
                        row.workTitle(), row.author(), row.body(), row.reason(), row.status(),
                        row.createdAt() == null ? null : row.createdAt().toInstant(ZoneOffset.UTC)))
                .toList();
        return PageResponse.of(safePage, safeSize, total, items);
    }

    /** 采纳举报：隐藏被举报的评论，并把工单标为 resolved。两步在同一个事务里。 */
    @Transactional
    public ConsoleDtos.ReportItem resolveReport(ConsolePrincipal principal, String reportId) {
        return handleReport(principal, reportId, "resolved",
                ConsoleAuditRepository.ACTION_UGC_REPORT_RESOLVE, true);
    }

    /** 驳回举报：只把工单标为 dismissed，**不动评论**。 */
    @Transactional
    public ConsoleDtos.ReportItem dismissReport(ConsolePrincipal principal, String reportId) {
        return handleReport(principal, reportId, "dismissed",
                ConsoleAuditRepository.ACTION_UGC_REPORT_DISMISS, false);
    }

    private ConsoleDtos.ReportItem handleReport(ConsolePrincipal principal, String reportId,
                                                String target, String action, boolean hideComment) {
        ConsoleScope scope = scopeResolver.resolve(principal);
        long id = parseReportId(reportId);
        var report = reportRepository.findById(scope.siteKey(), id)
                .orElseThrow(() -> new ApiException(ErrorCode.COMMENT_NOT_FOUND, "举报不存在"));
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        if ("open".equals(report.status())) {
            if (hideComment) {
                ugcRepository.updateStatus(scope.siteKey(), report.commentId(), "hidden", now);
            }
            reportRepository.markHandled(scope.siteKey(), id, target, principal.adminId(), now);
            auditRepository.record(scope.siteKey(), principal.adminId(), action, "ugc_report",
                    String.valueOf(id), report.status() + " -> " + target
                            + (hideComment ? "（并隐藏评论 " + report.commentId() + "）" : "（评论未动）"),
                    now);
        }
        return reportRepository.findById(scope.siteKey(), id)
                .map(row -> new ConsoleDtos.ReportItem(
                        String.valueOf(row.id()), String.valueOf(row.commentId()), row.workId(),
                        row.workTitle(), row.author(), row.body(), row.reason(), row.status(),
                        row.createdAt() == null ? null : row.createdAt().toInstant(ZoneOffset.UTC)))
                .orElseThrow(() -> new ApiException(ErrorCode.COMMENT_NOT_FOUND, "举报不存在"));
    }

    /**
     * 导出本站评论为 CSV（数据交还客户）。
     *
     * <p>上限 5 万行：够覆盖任何单站现阶段的数据量，又不会让一次请求把内存吃穿。
     * 超过上限时正常返回前 5 万行并标记 {@code truncated=true}——**不报错**，
     * 因为站主要的是「能拿到数据」，报错只会让他反复重试。
     */
    public ExportResult exportCsv(ConsolePrincipal principal, String status) {
        ConsoleScope scope = scopeResolver.resolve(principal);
        String filter = normalizeFilter(status);
        List<UgcRepository.ConsoleRow> rows =
                ugcRepository.findForConsole(scope.siteKey(), filter, MAX_EXPORT_ROWS, 0);
        long total = ugcRepository.countForConsole(scope.siteKey(), filter);
        boolean truncated = total > rows.size();

        auditRepository.record(scope.siteKey(), principal.adminId(),
                ConsoleAuditRepository.ACTION_UGC_EXPORT, "ugc_comment", scope.siteKey(),
                "导出 " + rows.size() + " 条（status=" + (filter == null ? "all" : filter) + "）",
                LocalDateTime.now(ZoneOffset.UTC));
        log.info("站主 {} 导出站点 {} 的 UGC：{} 条，truncated={}",
                principal.adminId(), scope.siteKey(), rows.size(), truncated);
        return new ExportResult(UgcCsvExporter.toCsv(rows), rows.size(), truncated);
    }

    public record ExportResult(String csv, int rows, boolean truncated) {
    }

    private static String normalizeReportFilter(String status) {
        if (status == null || status.isBlank() || "all".equals(status)) {
            return null;
        }
        String trimmed = status.trim();
        if (!REPORT_FILTERABLE.contains(trimmed)) {
            throw ApiException.badRequest("status 只能是 open / resolved / dismissed / all");
        }
        return trimmed;
    }

    private static long parseReportId(String raw) {
        try {
            return Long.parseLong(raw);
        } catch (NumberFormatException ex) {
            throw new ApiException(ErrorCode.COMMENT_NOT_FOUND, "举报不存在");
        }
    }

    private ConsoleDtos.UgcItem changeStatus(ConsolePrincipal principal, String commentId,
                                             String target, String action) {
        ConsoleScope scope = scopeResolver.resolve(principal);
        long id = parseId(commentId);
        var row = ugcRepository.findById(scope.siteKey(), id)
                .orElseThrow(() -> new ApiException(ErrorCode.COMMENT_NOT_FOUND, "评论不存在"));
        if (!row.status().equals(target)) {
            LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
            ugcRepository.updateStatus(scope.siteKey(), id, target, now);
            auditRepository.record(scope.siteKey(), principal.adminId(), action, "ugc_comment",
                    String.valueOf(id), row.status() + " -> " + target, now);
        }
        return ugcRepository.findForConsoleById(scope.siteKey(), id)
                .map(ConsoleUgcService::toItem)
                .orElseThrow(() -> new ApiException(ErrorCode.COMMENT_NOT_FOUND, "评论不存在"));
    }

    private static ConsoleDtos.UgcItem toItem(UgcRepository.ConsoleRow row) {
        return new ConsoleDtos.UgcItem(String.valueOf(row.id()), row.workId(), row.workTitle(),
                row.username(), row.body(), row.status(),
                row.createdAt() == null ? null : row.createdAt().toInstant(ZoneOffset.UTC));
    }

    private static String normalizeFilter(String status) {
        if (status == null || status.isBlank() || "all".equals(status)) {
            return null;
        }
        String trimmed = status.trim();
        if (!FILTERABLE.contains(trimmed)) {
            throw ApiException.badRequest("status 只能是 published / hidden / deleted / all");
        }
        return trimmed;
    }

    private static long parseId(String raw) {
        try {
            return Long.parseLong(raw);
        } catch (NumberFormatException ex) {
            throw new ApiException(ErrorCode.COMMENT_NOT_FOUND, "评论不存在");
        }
    }
}
