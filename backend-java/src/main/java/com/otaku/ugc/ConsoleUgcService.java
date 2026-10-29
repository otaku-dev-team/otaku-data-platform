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

    private static final Set<String> FILTERABLE = Set.of("published", "hidden", "deleted");
    private static final int MAX_PAGE_SIZE = 50;

    private final UgcRepository ugcRepository;
    private final UgcSettingsRepository settings;
    private final ConsoleScopeResolver scopeResolver;
    private final ConsoleAuditRepository auditRepository;

    public ConsoleUgcService(UgcRepository ugcRepository, UgcSettingsRepository settings,
                             ConsoleScopeResolver scopeResolver, ConsoleAuditRepository auditRepository) {
        this.ugcRepository = ugcRepository;
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
        return new ConsoleDtos.UgcSetting(settings.isEnabled(scope.siteKey()));
    }

    public ConsoleDtos.UgcSetting updateSetting(ConsolePrincipal principal, Boolean enabled) {
        if (enabled == null) {
            throw ApiException.badRequest("enabled 不能为空");
        }
        ConsoleScope scope = scopeResolver.resolve(principal);
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        settings.setEnabled(scope.siteKey(), enabled, now);
        auditRepository.record(scope.siteKey(), principal.adminId(),
                ConsoleAuditRepository.ACTION_UGC_SETTING, "site", scope.siteKey(),
                enabled ? "启用社区" : "关闭社区", now);
        log.info("站主 {} 把站点 {} 的 UGC 开关设为 {}", principal.adminId(), scope.siteKey(), enabled);
        return new ConsoleDtos.UgcSetting(enabled);
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
