package com.otaku.console;

import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.console.dto.ConsoleDtos;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.util.StringUtils;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.List;

/**
 * 站主名单的自助维护（二期，提案 §8 第 3 条「后续可由已授权站主邀请」）。
 *
 * <p>允许站主动的是**自己站点的人**，不是站点本身：新增的站主只能看到本站数据，
 * 站点配置、来源绑定仍然只在 {@code /internal/**}（红线不变）。
 *
 * <p>两条护栏，都是「没有它就会出事」而不是"更稳妥"：
 * <ol>
 *   <li>**不能停用自己**——手滑点错就再也进不来，只能找平台改库。
 *       有这一条之后，"本站失去最后一个站主"就不可能由这个接口造成：
 *       操作者自己必然是 active，停别人不会把站点清空；</li>
 *   <li>**目标必须属于本站**——按 admin_id 直接操作时，少一个 site_key 条件就是跨站越权。</li>
 * </ol>
 *
 * <p>停用 = 改状态 + 撤销该站主全部后台会话（与平台侧停用同一语义），
 * 不删行：删了无法审计、无法恢复，会话表也还引用着它。
 */
@Service
public class ConsoleAdminService {

    private static final Logger log = LoggerFactory.getLogger(ConsoleAdminService.class);

    static final String CREATED_NOTE =
            "站主已创建。初始口令由你设置，平台不保存明文，请通过可靠渠道转告；"
                    + "对方登录后可在「账号」里自行修改。新站主只能管理本站数据。";
    static final String DISABLED_NOTE =
            "已停用该站主并撤销其后台会话。站点本身与其他站主不受影响；"
                    + "恢复后对方需重新登录。";
    static final String ENABLED_NOTE =
            "已恢复该站主。此前的会话不会自动恢复，对方需重新登录。";

    private final ConsoleAdminRepository adminRepository;
    private final SiteAdminRepository siteAdminRepository;
    private final SiteAdminSessionRepository sessionRepository;
    private final ConsoleAuthService authService;
    private final ConsoleAuditRepository auditRepository;

    public ConsoleAdminService(ConsoleAdminRepository adminRepository,
                               SiteAdminRepository siteAdminRepository,
                               SiteAdminSessionRepository sessionRepository,
                               ConsoleAuthService authService,
                               ConsoleAuditRepository auditRepository) {
        this.adminRepository = adminRepository;
        this.siteAdminRepository = siteAdminRepository;
        this.sessionRepository = sessionRepository;
        this.authService = authService;
        this.auditRepository = auditRepository;
    }

    public List<ConsoleDtos.AdminItem> list(ConsolePrincipal principal) {
        return adminRepository.list(principal.siteKey()).stream()
                .map(item -> new ConsoleDtos.AdminItem(item.adminId(), item.username(),
                        item.displayName(), item.status(), item.createdAt(), item.lastLoginAt(),
                        item.adminId().equals(principal.adminId())))
                .toList();
    }

    @Transactional
    public ConsoleDtos.AdminCreated create(ConsolePrincipal principal, ConsoleDtos.AdminCreateRequest request) {
        if (request == null) {
            throw ApiException.badRequest("请求体不能为空");
        }
        // 复用平台侧的建号逻辑：用户名/口令校验、BCrypt、全局唯一冲突的处理都在一处，
        // 两边各写一份迟早会在"长度"或"冲突码"上分叉。
        ConsoleDtos.SiteAdminCreated created = authService.createAdmin(
                principal.siteKey(), request.username(), request.password(), request.displayName());
        audit(principal, ConsoleAuditRepository.ACTION_ADMIN_CREATE, created.adminId(),
                "username=" + created.username());
        log.info("站主 {} 新增站主 {}（站点 {}）", principal.adminId(), created.adminId(), principal.siteKey());
        return new ConsoleDtos.AdminCreated(created.adminId(), created.username(),
                created.displayName(), CREATED_NOTE);
    }

    @Transactional
    public ConsoleDtos.AdminStatusChange disable(ConsolePrincipal principal, String adminId) {
        SiteAdminRow target = requireTeammate(principal, adminId);
        if (!SiteAdminRow.STATUS_ACTIVE.equals(target.status())) {
            return new ConsoleDtos.AdminStatusChange(target.adminId(), target.username(),
                    target.status(), 0, DISABLED_NOTE);
        }
        if (target.adminId().equals(principal.adminId())) {
            throw ApiException.badRequest("不能停用自己：请让另一位站主操作，或联系平台");
        }
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        int revoked = sessionRepository.revokeAllForAdmin(target.id(), now);
        siteAdminRepository.updateStatus(target.adminId(), SiteAdminRow.STATUS_DISABLED, now);
        audit(principal, ConsoleAuditRepository.ACTION_ADMIN_DISABLE, target.adminId(),
                "username=" + target.username());
        log.info("站主 {} 停用站主 {}（站点 {}，撤销会话 {} 条）",
                principal.adminId(), target.adminId(), principal.siteKey(), revoked);
        return new ConsoleDtos.AdminStatusChange(target.adminId(), target.username(),
                SiteAdminRow.STATUS_DISABLED, revoked, DISABLED_NOTE);
    }

    @Transactional
    public ConsoleDtos.AdminStatusChange enable(ConsolePrincipal principal, String adminId) {
        SiteAdminRow target = requireTeammate(principal, adminId);
        if (SiteAdminRow.STATUS_ACTIVE.equals(target.status())) {
            return new ConsoleDtos.AdminStatusChange(target.adminId(), target.username(),
                    target.status(), 0, ENABLED_NOTE);
        }
        siteAdminRepository.updateStatus(target.adminId(), SiteAdminRow.STATUS_ACTIVE,
                LocalDateTime.now(ZoneOffset.UTC));
        audit(principal, ConsoleAuditRepository.ACTION_ADMIN_ENABLE, target.adminId(),
                "username=" + target.username());
        log.info("站主 {} 恢复站主 {}（站点 {}）", principal.adminId(), target.adminId(), principal.siteKey());
        return new ConsoleDtos.AdminStatusChange(target.adminId(), target.username(),
                SiteAdminRow.STATUS_ACTIVE, 0, ENABLED_NOTE);
    }

    /**
     * 取出本站的站主并校验归属。
     *
     * <p>404 与 403 分开：不存在/已不属于任何站点 → 404；存在但属于别站 → **403**。
     * 站主看到 403 才知道「不是记错了，是没权限」，这与用户管理同一套口径。
     */
    private SiteAdminRow requireTeammate(ConsolePrincipal principal, String adminId) {
        if (!StringUtils.hasText(adminId)) {
            throw ApiException.badRequest("缺少站主标识");
        }
        String id = adminId.trim();
        var found = adminRepository.find(id, principal.siteKey());
        if (found.isPresent()) {
            return found.get();
        }
        if (adminRepository.siteKeyOf(id).isPresent()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "无权操作其它站点的站主");
        }
        throw new ApiException(ErrorCode.ADMIN_NOT_FOUND, "站主不存在");
    }

    private void audit(ConsolePrincipal principal, String action, String targetId, String detail) {
        // 留痕失败不回滚操作：停用一个刷屏账号不该因为审计表抖动而失败。
        // 但必须留下日志，否则"审计悄悄不写了"没人知道。
        try {
            auditRepository.record(principal.siteKey(), principal.adminId(), action,
                    "admin", targetId, detail, LocalDateTime.now(ZoneOffset.UTC));
        } catch (RuntimeException ex) {
            log.warn("审计写入失败（action={}, target={}）：{}", action, targetId, ex.getMessage());
        }
    }
}
