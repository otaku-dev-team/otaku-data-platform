package com.otaku.console;

import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.console.dto.InternalSiteDtos;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDateTime;
import java.time.ZoneOffset;

/**
 * 平台侧的站点 / 站主状态流转（docs/site-owner-console.md §5.2）。
 *
 * <p>「停用」的语义与 {@link ConsoleUserService} 对用户的禁用**完全同构**：
 * 改状态 + 撤会话。只改状态挡得住下一次登录，挡不住已经打开的后台页面——
 * {@link ConsoleAuthService#authenticate} 里虽然有"每个请求联表判断状态"的双保险，
 * 但让一个被停用的站主看着自己的后台、每点一下就 403 一次，不如当场请他出去。
 *
 * <p>两个实体刻意分开成四条接口而不是一个通用的"toggle"：
 * 站点停用影响该站**所有**站主（撤的会话数也更多），出错时的爆炸半径完全不同，
 * 合并成一条会让调用方无法从路径上看出自己在动什么。
 *
 * <p>幂等：重复停用 / 重复启用不报错、不重复撤会话（返回 0），
 * 与用户禁用一致——运营侧重试是常态，接口不该把重试当错误。
 */
@Service
public class InternalLifecycleService {

    private static final Logger log = LoggerFactory.getLogger(InternalLifecycleService.class);

    static final String SITE_SUSPENDED_NOTE =
            "站点已停用：该站全部站主无法登录后台，已登录的会话已全部撤销。"
                    + "客户端数据（作品、用户）原样保留，重新启用后恢复可见。";
    static final String SITE_RESUMED_NOTE =
            "站点已恢复。此前的站主会话不会自动恢复，站主需要重新登录。";
    static final String ADMIN_DISABLED_NOTE =
            "站主账号已停用：无法再登录后台，已登录的会话已撤销。站点本身不受影响。";
    static final String ADMIN_ENABLED_NOTE =
            "站主账号已恢复。此前的会话不会自动恢复，需要重新登录。";

    private final SiteRepository siteRepository;
    private final SiteAdminRepository adminRepository;
    private final SiteAdminSessionRepository sessionRepository;

    public InternalLifecycleService(SiteRepository siteRepository,
                                    SiteAdminRepository adminRepository,
                                    SiteAdminSessionRepository sessionRepository) {
        this.siteRepository = siteRepository;
        this.adminRepository = adminRepository;
        this.sessionRepository = sessionRepository;
    }

    @Transactional
    public InternalSiteDtos.SiteStatusChange suspendSite(String siteKey) {
        SiteRecord site = requireSite(siteKey);
        if (!site.active()) {
            return new InternalSiteDtos.SiteStatusChange(site.siteKey(), site.status(), 0,
                    SITE_SUSPENDED_NOTE);
        }
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        int revoked = sessionRepository.revokeAllForSite(site.siteKey(), now);
        siteRepository.updateStatus(site.siteKey(), SiteRecord.STATUS_SUSPENDED, now);
        log.info("平台停用站点 {}（撤销站主会话 {} 条）", site.siteKey(), revoked);
        return new InternalSiteDtos.SiteStatusChange(site.siteKey(), SiteRecord.STATUS_SUSPENDED,
                revoked, SITE_SUSPENDED_NOTE);
    }

    @Transactional
    public InternalSiteDtos.SiteStatusChange resumeSite(String siteKey) {
        SiteRecord site = requireSite(siteKey);
        if (site.active()) {
            return new InternalSiteDtos.SiteStatusChange(site.siteKey(), site.status(), 0,
                    SITE_RESUMED_NOTE);
        }
        siteRepository.updateStatus(site.siteKey(), SiteRecord.STATUS_ACTIVE,
                LocalDateTime.now(ZoneOffset.UTC));
        log.info("平台恢复站点 {}", site.siteKey());
        return new InternalSiteDtos.SiteStatusChange(site.siteKey(), SiteRecord.STATUS_ACTIVE,
                0, SITE_RESUMED_NOTE);
    }

    @Transactional
    public InternalSiteDtos.SiteAdminStatusChange disableAdmin(String adminId) {
        SiteAdminRow admin = requireAdmin(adminId);
        if (!SiteAdminRow.STATUS_ACTIVE.equals(admin.status())) {
            return new InternalSiteDtos.SiteAdminStatusChange(admin.adminId(), admin.siteKey(),
                    admin.username(), admin.status(), 0, ADMIN_DISABLED_NOTE);
        }
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        int revoked = sessionRepository.revokeAllForAdmin(admin.id(), now);
        adminRepository.updateStatus(admin.adminId(), SiteAdminRow.STATUS_DISABLED, now);
        log.info("平台停用站主 {}（站点 {}，撤销会话 {} 条）", admin.adminId(), admin.siteKey(), revoked);
        return new InternalSiteDtos.SiteAdminStatusChange(admin.adminId(), admin.siteKey(),
                admin.username(), SiteAdminRow.STATUS_DISABLED, revoked, ADMIN_DISABLED_NOTE);
    }

    @Transactional
    public InternalSiteDtos.SiteAdminStatusChange enableAdmin(String adminId) {
        SiteAdminRow admin = requireAdmin(adminId);
        if (SiteAdminRow.STATUS_ACTIVE.equals(admin.status())) {
            return new InternalSiteDtos.SiteAdminStatusChange(admin.adminId(), admin.siteKey(),
                    admin.username(), admin.status(), 0, ADMIN_ENABLED_NOTE);
        }
        adminRepository.updateStatus(admin.adminId(), SiteAdminRow.STATUS_ACTIVE,
                LocalDateTime.now(ZoneOffset.UTC));
        log.info("平台恢复站主 {}（站点 {}）", admin.adminId(), admin.siteKey());
        return new InternalSiteDtos.SiteAdminStatusChange(admin.adminId(), admin.siteKey(),
                admin.username(), SiteAdminRow.STATUS_ACTIVE, 0, ADMIN_ENABLED_NOTE);
    }

    /** 站点不存在 → 404 SITE_NOT_FOUND；与"存在但已停用"（正常幂等返回）分开。 */
    private SiteRecord requireSite(String siteKey) {
        if (siteKey == null || siteKey.isBlank()) {
            throw ApiException.badRequest("缺少站点标识");
        }
        return siteRepository.find(siteKey.trim())
                .orElseThrow(() -> new ApiException(ErrorCode.SITE_NOT_FOUND, "站点不存在：" + siteKey));
    }

    /** 站主不存在 → 404 ADMIN_NOT_FOUND（按 admin_id 找，不暴露自增主键）。 */
    private SiteAdminRow requireAdmin(String adminId) {
        if (adminId == null || adminId.isBlank()) {
            throw ApiException.badRequest("缺少站主标识");
        }
        return adminRepository.findByAdminId(adminId.trim())
                .orElseThrow(() -> new ApiException(ErrorCode.ADMIN_NOT_FOUND, "站主不存在：" + adminId));
    }
}
