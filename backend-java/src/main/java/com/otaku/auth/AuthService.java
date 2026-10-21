package com.otaku.auth;

import com.otaku.auth.dto.LoginRequest;
import com.otaku.auth.dto.SessionResponse;
import com.otaku.auth.dto.UserDto;
import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.common.PublicIdGenerator;
import com.otaku.common.SessionTokens;
import com.otaku.session.SessionRecord;
import com.otaku.session.SessionRepository;
import com.otaku.user.UserRecord;
import com.otaku.user.UserRepository;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.util.StringUtils;

import java.time.Duration;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.Optional;

/**
 * 登录、鉴权、退出，以及内部建号。
 *
 * 与 docs/stage2-account-collection-contract.md 的对应：
 * - §1.2 不透明令牌 + 服务端会话（可即时撤销，C9 天然成立）
 * - §3.1 口令只存 BCrypt(cost 10)，明文不落库、不进日志
 * - §3.2 一次登录一条会话、30 天固定有效期、不滑动续期、退出只撤当前这条
 * - §4.1 登录失败统一 INVALID_CREDENTIALS，不区分「用户不存在」与「密码错」
 * - §11.7 不开放自助注册，账号走内部建号接口
 */
@Service
public class AuthService {

    static final Duration SESSION_TTL = Duration.ofDays(30);
    private static final Duration TOUCH_INTERVAL = Duration.ofMinutes(5);
    private static final int USERNAME_MIN = 3;
    private static final int USERNAME_MAX = 32;
    private static final int PASSWORD_MIN = 8;
    private static final int PASSWORD_MAX = 72;
    private static final int BCRYPT_COST = 10;

    private final UserRepository userRepository;
    private final SessionRepository sessionRepository;
    private final PublicIdGenerator idGenerator;
    private final LoginThrottle loginThrottle;
    private final BCryptPasswordEncoder passwordEncoder = new BCryptPasswordEncoder(BCRYPT_COST);

    public AuthService(UserRepository userRepository, SessionRepository sessionRepository,
                       PublicIdGenerator idGenerator, LoginThrottle loginThrottle) {
        this.userRepository = userRepository;
        this.sessionRepository = sessionRepository;
        this.idGenerator = idGenerator;
        this.loginThrottle = loginThrottle;
    }

    /** 内部建号（POST /internal/accounts）：不返回会话，账号由负责人创建。 */
    public UserDto createAccount(String usernameRaw, String passwordRaw) {
        String username = validateUsername(usernameRaw);
        String password = validatePassword(passwordRaw);

        if (userRepository.existsByUsername(username)) {
            throw new ApiException(ErrorCode.USERNAME_TAKEN, "用户名已被占用");
        }
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        try {
            userRepository.insert(new UserRecord(null, idGenerator.nextUserId(), username,
                    passwordEncoder.encode(password), now, now));
        } catch (DuplicateKeyException ex) {
            throw new ApiException(ErrorCode.USERNAME_TAKEN, "用户名已被占用");
        }
        UserRecord saved = userRepository.findByUsername(username)
                .orElseThrow(() -> new ApiException(ErrorCode.INTERNAL, "建号后读取用户失败"));
        return toDto(saved);
    }

    public SessionResponse login(LoginRequest request) {
        String username = request.username() == null ? "" : request.username().trim();
        String password = request.password() == null ? "" : request.password();

        // 先看限流：超限时连口令比对都不做，既省 BCrypt 的 CPU，也不给暴力试错留时间窗
        loginThrottle.checkAllowed(username);

        Optional<UserRecord> found = userRepository.findByUsername(username);
        if (found.isEmpty() || !passwordEncoder.matches(password, found.get().passwordHash())) {
            loginThrottle.recordFailure(username);
            throw new ApiException(ErrorCode.INVALID_CREDENTIALS, "账号或密码不正确");
        }
        loginThrottle.clear(username);
        return startSession(found.get(), request.deviceLabel());
    }

    /** 校验令牌并返回对应用户；无效/过期/已撤销都返回空。 */
    public Optional<UserRecord> authenticate(String token) {
        if (!StringUtils.hasText(token)) {
            return Optional.empty();
        }
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        Optional<SessionRecord> session = sessionRepository.findActive(SessionTokens.hash(token), now);
        if (session.isEmpty()) {
            return Optional.empty();
        }
        Optional<UserRecord> user = userRepository.findById(session.get().userPk());
        if (user.isEmpty()) {
            return Optional.empty();
        }
        SessionRecord record = session.get();
        if (record.lastSeenAt() == null || record.lastSeenAt().isBefore(now.minus(TOUCH_INTERVAL))) {
            sessionRepository.touch(record.id(), now);
        }
        return user;
    }

    /** 只撤销当前令牌；令牌缺失或已失效都返回 false，调用方按幂等 204 处理。 */
    public boolean logout(String token) {
        if (!StringUtils.hasText(token)) {
            return false;
        }
        return sessionRepository.revoke(SessionTokens.hash(token),
                LocalDateTime.now(ZoneOffset.UTC)) > 0;
    }

    public static UserDto toDto(UserRecord user) {
        return new UserDto(user.userId(), user.username(), null,
                user.createdAt() == null ? null : user.createdAt().toInstant(ZoneOffset.UTC));
    }

    private SessionResponse startSession(UserRecord user, String deviceLabel) {
        String token = SessionTokens.newToken();
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        LocalDateTime expiresAt = now.plus(SESSION_TTL);
        String label = StringUtils.hasText(deviceLabel) ? deviceLabel.trim() : null;
        if (label != null && label.length() > 64) {
            label = label.substring(0, 64);
        }
        sessionRepository.create(user.id(), SessionTokens.hash(token), label, now, expiresAt);
        return new SessionResponse(token, expiresAt.toInstant(ZoneOffset.UTC), toDto(user));
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

    private static String validatePassword(String raw) {
        String password = raw == null ? "" : raw;
        if (password.length() < PASSWORD_MIN || password.length() > PASSWORD_MAX) {
            throw ApiException.badRequest("密码长度需在 " + PASSWORD_MIN + "-" + PASSWORD_MAX + " 个字符之间");
        }
        return password;
    }
}
