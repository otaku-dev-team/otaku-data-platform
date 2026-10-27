package com.otaku.console;

import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.collection.CollectionRepository;
import com.otaku.collection.CollectionWorkRow;
import com.otaku.common.PageResponse;
import com.otaku.console.dto.ConsoleDtos;
import com.otaku.session.SessionRepository;
import com.otaku.user.UserRecord;
import com.otaku.user.UserRepository;
import com.otaku.work.WorkService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.util.StringUtils;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.List;

/**
 * 站主后台的用户管理（首版只做列表 + 禁用/解禁，提案 §8 第 4 条）。
 *
 * <p>「禁用」的边界（提案 §4.2，已拍板）：**只封这个用户在本站的客户端登录**，
 * 不碰网站账号。落到代码上就是两件事：
 * <ol>
 *   <li>{@code app_user.status = 'disabled'}——登录时 403（{@link com.otaku.auth.AuthService}）；</li>
 *   <li>撤销该用户所有平台会话——已经在用的设备立刻掉线，不用等 30 天过期。</li>
 * </ol>
 * 平台**没有**任何回写网站账号状态的代码路径。响应里的 {@code note} 会把这句话原样告诉站主，
 * 免得他以为拿到了网站账号的生杀大权（上线后才发现不是，比一开始就说清楚更伤人）。
 */
@Service
public class ConsoleUserService {

    private static final Logger log = LoggerFactory.getLogger(ConsoleUserService.class);

    static final int PAGE_SIZE_MAX = 50;
    static final String DISABLED_NOTE =
            "已禁用该账号在本站的客户端登录，并撤销其已登录会话。"
                    + "注意：网站账号不受影响——该用户仍可登录网站，只是不能再用本站客户端。";
    static final String ENABLED_NOTE =
            "已恢复客户端登录。此前的会话不会自动恢复，用户需要用原账号重新登录。";

    private final ConsoleUserRepository consoleUserRepository;
    private final UserRepository userRepository;
    private final SessionRepository sessionRepository;
    private final CollectionRepository collectionRepository;
    private final WorkService workService;
    private final ConsoleAuditRepository auditRepository;

    public ConsoleUserService(ConsoleUserRepository consoleUserRepository,
                              UserRepository userRepository,
                              SessionRepository sessionRepository,
                              CollectionRepository collectionRepository,
                              WorkService workService,
                              ConsoleAuditRepository auditRepository) {
        this.consoleUserRepository = consoleUserRepository;
        this.userRepository = userRepository;
        this.sessionRepository = sessionRepository;
        this.collectionRepository = collectionRepository;
        this.workService = workService;
        this.auditRepository = auditRepository;
    }

    public PageResponse<ConsoleDtos.UserItem> list(ConsolePrincipal principal, String status,
                                                   String keyword, int page, int pageSize) {
        String normalizedStatus = normalizeStatus(status);
        int safePage = Math.max(page, 1);
        int safeSize = Math.min(Math.max(pageSize, 1), PAGE_SIZE_MAX);

        long total = consoleUserRepository.count(principal.siteKey(), normalizedStatus, keyword);
        List<ConsoleDtos.UserItem> items = total == 0
                ? List.of()
                : consoleUserRepository.page(principal.siteKey(), normalizedStatus, keyword,
                safeSize, (safePage - 1) * safeSize, LocalDateTime.now(ZoneOffset.UTC));
        return PageResponse.of(safePage, safeSize, total, items);
    }

    /**
     * 用户详情（二期）：基本信息 + 会话数 + 收藏聚合。
     *
     * <p>收藏明细单独分页（{@link #collections}）：一个人的收藏可能上千条，
     * 塞进详情会让这个接口变成"一次拉全量"的入口，而站主多数时候只想看总数。
     */
    public ConsoleDtos.UserDetail detail(ConsolePrincipal principal, String userId) {
        UserRecord user = ownedUser(principal, userId);
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        return new ConsoleDtos.UserDetail(
                user.userId(),
                user.username(),
                user.status(),
                toOffset(user.createdAt()),
                toOffset(user.statusChangedAt()),
                consoleUserRepository.countActiveSessions(user.id(), now),
                consoleUserRepository.collectionStats(user.id()));
    }

    /**
     * 某个本站用户的收藏明细（二期）。
     *
     * <p>先做归属校验再查收藏——顺序反了就是越权：先按 user_id 查出数据、
     * 再判断"是不是本站的"，中间那一步已经把别人的数据读进内存了。
     * 这里用 {@link #ownedUser} 一次挡掉"不存在（404）/ 别站（403）"。
     */
    public PageResponse<ConsoleDtos.UserCollectionItem> collections(ConsolePrincipal principal, String userId,
                                                                    String status, int page, int pageSize) {
        UserRecord user = ownedUser(principal, userId);
        String normalizedStatus = normalizeCollectionStatus(status);
        int safePage = Math.max(page, 1);
        int safeSize = Math.min(Math.max(pageSize, 1), PAGE_SIZE_MAX);

        long total = collectionRepository.count(user.id(), normalizedStatus);
        List<ConsoleDtos.UserCollectionItem> items = total == 0
                ? List.of()
                : collectionRepository.findPage(user.id(), normalizedStatus,
                        safeSize, (safePage - 1) * safeSize).stream()
                .map(this::toCollectionItem)
                .toList();
        return PageResponse.of(safePage, safeSize, total, items);
    }

    private ConsoleDtos.UserCollectionItem toCollectionItem(CollectionWorkRow row) {
        return new ConsoleDtos.UserCollectionItem(
                row.workId(),
                row.title(),
                row.workType(),
                row.status(),
                // 封面仍走平台代理：站主看到的是与客户端一致的地址，也不把来源站暴露给前端
                workService.coverUrl(row.workId(), row.coverSourceUrl()),
                toOffset(row.updatedAt()));
    }

    @Transactional
    public ConsoleDtos.UserStatusChange disable(ConsolePrincipal principal, String userId, String reason) {
        UserRecord user = ownedUser(principal, userId);
        if (!user.active()) {
            // 幂等：已经禁用了再点一次，不报错，也不再撤一遍会话
            return new ConsoleDtos.UserStatusChange(user.userId(), UserRecord.STATUS_DISABLED, 0, DISABLED_NOTE);
        }
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        int revoked = sessionRepository.revokeAllForUser(user.id(), now);
        userRepository.updateStatus(user.id(), UserRecord.STATUS_DISABLED, now);
        String auditReason = StringUtils.hasText(reason) ? reason.trim() : "未填写";
        log.info("站主 {} 禁用用户 {}（撤销会话 {} 条，原因：{}）",
                principal.adminId(), user.userId(), revoked, auditReason);
        audit(principal, ConsoleAuditRepository.ACTION_USER_DISABLE, user.userId(),
                "reason=" + auditReason);
        return new ConsoleDtos.UserStatusChange(user.userId(), UserRecord.STATUS_DISABLED, revoked, DISABLED_NOTE);
    }

    @Transactional
    public ConsoleDtos.UserStatusChange enable(ConsolePrincipal principal, String userId) {
        UserRecord user = ownedUser(principal, userId);
        if (user.active()) {
            return new ConsoleDtos.UserStatusChange(user.userId(), UserRecord.STATUS_ACTIVE, 0, ENABLED_NOTE);
        }
        userRepository.updateStatus(user.id(), UserRecord.STATUS_ACTIVE, LocalDateTime.now(ZoneOffset.UTC));
        log.info("站主 {} 解禁用户 {}", principal.adminId(), user.userId());
        audit(principal, ConsoleAuditRepository.ACTION_USER_ENABLE, user.userId(), null);
        return new ConsoleDtos.UserStatusChange(user.userId(), UserRecord.STATUS_ACTIVE, 0, ENABLED_NOTE);
    }

    /**
     * 取出用户并校验归属。
     *
     * <p>三种结果刻意分开（而不是统一 404）：
     * 账号不存在 → 404；账号存在但不属于本站（含 site_key 为空的历史账号）→ **403**。
     * 契约要求 403，是为了让"我没权限"和"没这个人"在站主那边能区分开——
     * 前者该找平台要权限，后者该检查是不是记错了账号。
     */
    private UserRecord ownedUser(ConsolePrincipal principal, String userId) {
        if (!StringUtils.hasText(userId)) {
            throw ApiException.badRequest("缺少用户标识");
        }
        UserRecord user = userRepository.findByUserId(userId.trim())
                .orElseThrow(() -> new ApiException(ErrorCode.USER_NOT_FOUND, "用户不存在"));
        if (user.siteKey() == null || !user.siteKey().equals(principal.siteKey())) {
            throw new ApiException(ErrorCode.FORBIDDEN, "无权操作其它站点的用户");
        }
        return user;
    }

    /** 收藏状态过滤：与客户端同一套取值；{@code none} 表示「收藏了但没设状态」。 */
    private static String normalizeCollectionStatus(String raw) {
        if (!StringUtils.hasText(raw)) {
            return null;
        }
        String status = raw.trim().toLowerCase();
        if (!"want".equals(status) && !"watching".equals(status)
                && !"watched".equals(status) && !"none".equals(status)) {
            throw ApiException.badRequest("status 只能是 want / watching / watched / none");
        }
        return status;
    }

    private void audit(ConsolePrincipal principal, String action, String targetId, String detail) {
        try {
            auditRepository.record(principal.siteKey(), principal.adminId(), action,
                    "user", targetId, detail, LocalDateTime.now(ZoneOffset.UTC));
        } catch (RuntimeException ex) {
            log.warn("审计写入失败（action={}, target={}）：{}", action, targetId, ex.getMessage());
        }
    }

    private static java.time.OffsetDateTime toOffset(LocalDateTime value) {
        return value == null ? null : value.atOffset(ZoneOffset.UTC);
    }

    private static String normalizeStatus(String raw) {
        if (!StringUtils.hasText(raw)) {
            return null;
        }
        String status = raw.trim().toLowerCase();
        if (!UserRecord.STATUS_ACTIVE.equals(status) && !UserRecord.STATUS_DISABLED.equals(status)) {
            throw ApiException.badRequest("status 只能是 active 或 disabled");
        }
        return status;
    }
}
