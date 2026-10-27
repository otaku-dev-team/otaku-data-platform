package com.otaku.console;

import com.otaku.auth.LoginThrottle;
import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.common.PublicIdGenerator;
import com.otaku.common.SessionTokens;
import com.otaku.console.dto.ConsoleDtos;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.util.StringUtils;

import java.time.Duration;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.Optional;

/**
 * 站主后台的登录、鉴权、退出。
 *
 * <p>与客户端登录（{@link com.otaku.auth.AuthService}）刻意**不共用**：
 *
 * <ul>
 *   <li>凭据域不同——站主不是 App 用户，两套表、两套会话；</li>
 *   <li>有效期不同——后台 12 小时（管理权限，越短越好），客户端 30 天；</li>
 *   <li>失败限流复用同一个 {@link LoginThrottle} 也没用：它按用户名计数，
 *       两套账号的用户名空间互不相干，共用只会让计数表被两拨人搅在一起。</li>
 * </ul>
 *
 * <p>登录失败**不区分**「站主不存在」和「密码错」（同 {@code INVALID_CREDENTIALS}，避免枚举）；
 * 但「密码对了、账号/站点被停用」返回 403 并说明原因——这需要先猜对密码，不构成信息泄露，
 * 而站主看到"密码不对"会去反复重置，反而更难查。
 */
@Service
public class ConsoleAuthService {

    /** 12 小时固定有效期，不滑动续期：后台不该"用着用着一直有效"。 */
    static final Duration SESSION_TTL = Duration.ofHours(12);
    private static final Duration TOUCH_INTERVAL = Duration.ofMinutes(5);
    private static final int BCRYPT_COST = 10;
    private static final int PASSWORD_MIN = 8;
    private static final int PASSWORD_MAX = 72;
    private static final int USERNAME_MIN = 3;
    private static final int USERNAME_MAX = 64;

    private final SiteAdminRepository adminRepository;
    private final SiteAdminSessionRepository sessionRepository;
    private final PublicIdGenerator idGenerator;
    private final LoginThrottle loginThrottle;
    private final BCryptPasswordEncoder passwordEncoder = new BCryptPasswordEncoder(BCRYPT_COST);

    public ConsoleAuthService(SiteAdminRepository adminRepository,
                              SiteAdminSessionRepository sessionRepository,
                              PublicIdGenerator idGenerator,
                              LoginThrottle loginThrottle) {
        this.adminRepository = adminRepository;
        this.sessionRepository = sessionRepository;
        this.idGenerator = idGenerator;
        this.loginThrottle = loginThrottle;
    }

    public ConsoleDtos.SessionResponse login(ConsoleDtos.LoginRequest request) {
        String username = request == null || request.username() == null ? "" : request.username().trim();
        String password = request == null || request.password() == null ? "" : request.password();

        loginThrottle.checkAllowed(username);

        Optional<SiteAdminRow> found = adminRepository.findByUsername(username);
        // passwordHash 为空 = 走网站账号登录的站主，平台侧没有口令可比 —— 一律按失败处理
        if (found.isEmpty() || found.get().passwordHash() == null
                || !passwordEncoder.matches(password, found.get().passwordHash())) {
            loginThrottle.recordFailure(username);
            throw new ApiException(ErrorCode.INVALID_CREDENTIALS, "账号或密码不正确");
        }
        SiteAdminRow admin = found.get();
        if (!admin.active()) {
            throw new ApiException(ErrorCode.FORBIDDEN,
                    SiteAdminRow.STATUS_DISABLED.equals(admin.status())
                            ? "站主账号已停用，请联系平台运营"
                            : "站点已停用，后台不可用");
        }
        loginThrottle.clear(username);

        String token = SessionTokens.newToken();
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        LocalDateTime expiresAt = now.plus(SESSION_TTL);
        sessionRepository.create(admin.id(), SessionTokens.hash(token), label(request.deviceLabel()), now, expiresAt);
        adminRepository.touchLogin(admin.id(), now);

        return new ConsoleDtos.SessionResponse(token, expiresAt.atOffset(ZoneOffset.UTC),
                new ConsoleDtos.SiteView(admin.siteKey(), admin.siteName()),
                new ConsoleDtos.AdminView(admin.adminId(), admin.username(), admin.displayName(),
                        admin.identitySource()));
    }

    /**
     * 校验令牌。无效/过期/已撤销返回空；**站主或站点被停用则抛 403**。
     *
     * <p>为什么停用要单独抛：如果和"令牌无效"一样返回 401，站主会以为是自己掉线了，
     * 反复登录只会不断撞同一堵墙，而真正的原因（账号被停用）永远看不到。
     */
    public Optional<ConsolePrincipal> authenticate(String token) {
        if (!StringUtils.hasText(token)) {
            return Optional.empty();
        }
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        String hash = SessionTokens.hash(token);
        Optional<Long> adminPk = sessionRepository.findActiveAdminPk(hash, now);
        if (adminPk.isEmpty()) {
            return Optional.empty();
        }
        Optional<SiteAdminRow> admin = adminRepository.findSessionOwner(adminPk.get());
        if (admin.isEmpty()) {
            return Optional.empty();
        }
        SiteAdminRow row = admin.get();
        if (!row.active()) {
            throw new ApiException(ErrorCode.FORBIDDEN,
                    SiteAdminRow.STATUS_DISABLED.equals(row.status())
                            ? "站主账号已停用，请联系平台运营"
                            : "站点已停用，后台不可用");
        }
        sessionRepository.touch(hash, now);
        return Optional.of(new ConsolePrincipal(row.id(), row.adminId(), row.username(),
                row.displayName(), row.identitySource(), row.siteKey(), row.siteName()));
    }

    /**
     * 修改自己的口令（二期，配合"站主可自助新增站主"）。
     *
     * <p>没有它，新增出来的站主口令只能由创建者一直记着、或由平台改库重置——
     * 那是运营事故的温床（口令通过聊天工具传来传去）。
     *
     * <p>成功后撤销**其它设备**的会话、保留当前这台：改口令的常见场景是"怀疑泄露"，
     * 此时把所有设备都踢掉会连自己一起踢，用户会以为改失败了。
     */
    @Transactional
    public void changePassword(ConsolePrincipal principal, String currentToken,
                               ConsoleDtos.PasswordChangeRequest request) {
        String oldPassword = request == null || request.oldPassword() == null ? "" : request.oldPassword();
        String newPassword = request == null || request.newPassword() == null ? "" : request.newPassword();
        validatePassword(newPassword);
        if (oldPassword.equals(newPassword)) {
            throw ApiException.badRequest("新口令不能与旧口令相同");
        }
        SiteAdminRow row = adminRepository.findSessionOwner(principal.adminPk())
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED, "登录态已失效，请重新登录"));
        if (row.passwordHash() == null || !passwordEncoder.matches(oldPassword, row.passwordHash())) {
            throw new ApiException(ErrorCode.INVALID_CREDENTIALS, "当前口令不正确");
        }
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        adminRepository.updatePassword(row.adminId(), passwordEncoder.encode(newPassword), now);
        if (StringUtils.hasText(currentToken)) {
            sessionRepository.revokeOthers(row.id(), SessionTokens.hash(currentToken), now);
        }
    }

    public void logout(String token) {
        if (!StringUtils.hasText(token)) {
            return;
        }
        sessionRepository.revoke(SessionTokens.hash(token), LocalDateTime.now(ZoneOffset.UTC));
    }

    /** 平台侧开设站主（/internal/site-admins）。用户名全局唯一，冲突由唯一索引兜底。 */
    public ConsoleDtos.SiteAdminCreated createAdmin(String siteKey, String usernameRaw, String password,
                                                    String displayName) {
        String username = validateUsername(usernameRaw);
        validatePassword(password);
        String adminId = idGenerator.nextAdminId();
        String name = StringUtils.hasText(displayName) ? displayName.trim() : null;
        try {
            adminRepository.insert(adminId, siteKey, username, passwordEncoder.encode(password),
                    name, SiteAdminRow.IDENTITY_PLATFORM, null, LocalDateTime.now(ZoneOffset.UTC));
        } catch (DuplicateKeyException ex) {
            throw new ApiException(ErrorCode.USERNAME_TAKEN, "站主用户名已被占用");
        } catch (DataIntegrityViolationException ex) {
            throw ApiException.badRequest("站点不存在：" + siteKey);
        }
        return new ConsoleDtos.SiteAdminCreated(adminId, siteKey, username, name);
    }

    private static String validateUsername(String raw) {
        String username = raw == null ? "" : raw.trim();
        if (username.length() < USERNAME_MIN || username.length() > USERNAME_MAX) {
            throw ApiException.badRequest("用户名长度需在 " + USERNAME_MIN + "-" + USERNAME_MAX + " 个字符之间");
        }
        if (username.chars().anyMatch(Character::isWhitespace)) {
            throw ApiException.badRequest("用户名不能包含空白字符");
        }
        return username;
    }

    private static void validatePassword(String raw) {
        String password = raw == null ? "" : raw;
        if (password.length() < PASSWORD_MIN || password.length() > PASSWORD_MAX) {
            throw ApiException.badRequest("密码长度需在 " + PASSWORD_MIN + "-" + PASSWORD_MAX + " 个字符之间");
        }
    }

    private static String label(String raw) {
        if (!StringUtils.hasText(raw)) {
            return null;
        }
        String trimmed = raw.trim();
        return trimmed.length() > 64 ? trimmed.substring(0, 64) : trimmed;
    }
}
