package com.otaku.auth;

import com.otaku.auth.dto.LoginRequest;
import com.otaku.auth.dto.RegisterRequest;
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
 * 注册、登录、鉴权与退出。
 *
 * 几条刻意的选择：
 * - 口令用 BCrypt（强度默认 10），库里只有摘要；
 * - 登录失败一律返回 INVALID_CREDENTIALS，不区分"用户不存在"和"口令错"，避免枚举账号；
 * - 每次登录新建会话，不撤销旧会话（验收 C1：一端登录不能把另一端踢下线）；
 * - 令牌只存 SHA-256 摘要，退出登录只撤当前这一条（C9）。
 */
@Service
public class AuthService {

    static final Duration SESSION_TTL = Duration.ofDays(30);
    private static final Duration TOUCH_INTERVAL = Duration.ofMinutes(5);
    private static final int USERNAME_MIN = 3;
    private static final int USERNAME_MAX = 32;
    private static final int PASSWORD_MIN = 8;
    private static final int PASSWORD_MAX = 72;

    private final UserRepository userRepository;
    private final SessionRepository sessionRepository;
    private final PublicIdGenerator idGenerator;
    private final BCryptPasswordEncoder passwordEncoder = new BCryptPasswordEncoder();

    public AuthService(UserRepository userRepository, SessionRepository sessionRepository,
                       PublicIdGenerator idGenerator) {
        this.userRepository = userRepository;
        this.sessionRepository = sessionRepository;
        this.idGenerator = idGenerator;
    }

    public SessionResponse register(RegisterRequest request) {
        String username = validateUsername(request.username());
        String password = validatePassword(request.password());

        if (userRepository.existsByUsername(username)) {
            throw new ApiException(ErrorCode.USERNAME_TAKEN, "用户名已被占用");
        }

        LocalDateTime now = nowUtc();
        UserRecord user = new UserRecord(null, idGenerator.nextUserId(), username,
                passwordEncoder.encode(password), now, now);
        try {
            userRepository.insert(user);
        } catch (DuplicateKeyException ex) {
            // 并发注册同名：唯一索引兜底
            throw new ApiException(ErrorCode.USERNAME_TAKEN, "用户名已被占用");
        }

        UserRecord saved = userRepository.findByUsername(username)
                .orElseThrow(() -> new ApiException(ErrorCode.INTERNAL, "注册后读取用户失败"));
        return startSession(saved, request.deviceLabel());
    }

    public SessionResponse login(LoginRequest request) {
        String username = request.username() == null ? "" : request.username().trim();
        String password = request.password() == null ? "" : request.password();

        Optional<UserRecord> found = userRepository.findByUsername(username);
        if (found.isEmpty() || !passwordEncoder.matches(password, found.get().passwordHash())) {
            throw new ApiException(ErrorCode.INVALID_CREDENTIALS, "用户名或密码错误");
        }
        return startSession(found.get(), request.deviceLabel());
    }

    /** 校验令牌并返回对应用户；无效/过期/已撤销都返回空。 */
    public Optional<UserRecord> authenticate(String token) {
        if (!StringUtils.hasText(token)) {
            return Optional.empty();
        }
        LocalDateTime now = nowUtc();
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

    /** 只撤销当前令牌；返回是否真的撤销了一条。 */
    public boolean logout(String token) {
        if (!StringUtils.hasText(token)) {
            return false;
        }
        return sessionRepository.revoke(SessionTokens.hash(token), nowUtc()) > 0;
    }

    public static UserDto toDto(UserRecord user) {
        return new UserDto(user.userId(), user.username(),
                user.createdAt() == null ? null : user.createdAt().toInstant(ZoneOffset.UTC));
    }

    private SessionResponse startSession(UserRecord user, String deviceLabel) {
        String token = SessionTokens.newToken();
        LocalDateTime now = nowUtc();
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

    private static LocalDateTime nowUtc() {
        return LocalDateTime.now(ZoneOffset.UTC);
    }
}
