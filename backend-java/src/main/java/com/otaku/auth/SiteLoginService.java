package com.otaku.auth;

import com.otaku.auth.dto.SessionResponse;
import com.otaku.auth.dto.SiteLoginRequest;
import com.otaku.auth.dto.UserDto;
import com.otaku.auth.site.SiteAuthClient;
import com.otaku.auth.site.SiteAuthException;
import com.otaku.auth.site.SiteAuthFailure;
import com.otaku.auth.site.SiteTokenResponse;
import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.common.PublicIdGenerator;
import com.otaku.common.SessionTokens;
import com.otaku.config.AppProperties;
import com.otaku.user.UserRecord;
import com.otaku.user.UserRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.util.StringUtils;

import java.security.SecureRandom;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.HexFormat;

/**
 * 站点授权票据换平台会话（契约 identity-linkup-contract.md §2，Issue #242）。
 *
 * <p>平台侧形态是「令牌交换代理」：client_secret 只在后端，客户端拿一次性 ticket
 * 来换平台会话，此后与口令登录的会话无差异。流程：
 *
 * <ol>
 *   <li>带 secret 调站点 {@code POST /api/auth/token} 换 access_token + user；</li>
 *   <li>按 {@code (identity_source, external_user_id)} 查/建账号映射（§3）；</li>
 *   <li>建平台会话（与口令登录同表同 TTL，令牌只存哈希）。</li>
 * </ol>
 *
 * <p>错误归一（契约 §7）：站点 detail 原文只进服务端日志，客户端只看到平台错误码；
 * 授权失败 401（重走授权可解），站点不可用 503（重走授权无用）。
 */
@Service
public class SiteLoginService {

    private static final Logger log = LoggerFactory.getLogger(SiteLoginService.class);
    private static final int USERNAME_MAX = 32;
    private static final String USERNAME_PREFIX = "site_";
    private static final int BCRYPT_COST = 10;

    private final SiteAuthClient siteAuthClient;
    private final SiteIdentityRepository identityRepository;
    private final UserRepository userRepository;
    private final AuthService authService;
    private final PublicIdGenerator idGenerator;
    private final AppProperties properties;
    private final BCryptPasswordEncoder passwordEncoder = new BCryptPasswordEncoder(BCRYPT_COST);
    private final SecureRandom random = new SecureRandom();

    public SiteLoginService(SiteAuthClient siteAuthClient, SiteIdentityRepository identityRepository,
                            UserRepository userRepository, AuthService authService,
                            PublicIdGenerator idGenerator, AppProperties properties) {
        this.siteAuthClient = siteAuthClient;
        this.identityRepository = identityRepository;
        this.userRepository = userRepository;
        this.authService = authService;
        this.idGenerator = idGenerator;
        this.properties = properties;
    }

    public SessionResponse siteLogin(SiteLoginRequest request) {
        String ticket = request == null || request.ticket() == null ? "" : request.ticket().trim();
        if (ticket.isEmpty()) {
            throw ApiException.badRequest("缺少站点授权票据");
        }

        String identitySource = properties.getSiteOauth().getIdentitySource();
        if (!StringUtils.hasText(identitySource)) {
            // 与 base-url / secret 同一口径：没配齐就是「站点登录未配置」，503 而不是放行。
            log.warn("site-oauth identity-source 未配置，拒绝站点登录");
            throw new ApiException(ErrorCode.SITE_UNAVAILABLE, "站点登录暂不可用，请稍后再试");
        }

        SiteTokenResponse site = exchange(ticket);

        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        String tokenHash = SessionTokens.hash(site.accessToken());
        LocalDateTime tokenExpiresAt = now.plus(properties.getSiteOauth().getTokenTtl());

        long userPk = findOrCreateMapping(identitySource, site, tokenHash, tokenExpiresAt, now);
        UserRecord user = userRepository.findById(userPk)
                .orElseThrow(() -> new ApiException(ErrorCode.INTERNAL, "站点映射账号读取失败"));

        // nickname / avatar_url 只在这一步透出给客户端展示（契约 §7），不落库、不再分发。
        UserDto dto = new UserDto(user.userId(), user.username(), site.nickname(),
                user.createdAt() == null ? null : user.createdAt().toInstant(ZoneOffset.UTC));
        SessionResponse session = authService.openSession(user, null);
        return new SessionResponse(session.token(), session.expiresAt(), dto);
    }

    private SiteTokenResponse exchange(String ticket) {
        try {
            return siteAuthClient.exchange(ticket);
        } catch (SiteAuthException ex) {
            if (ex.failure() == SiteAuthFailure.AUTH_FAILED) {
                // 票据过期/已用/secret 错：401，客户端引导重走授权（契约 §2）。
                throw new ApiException(ErrorCode.INVALID_CREDENTIALS, "站点授权已失效，请重新登录");
            }
            throw new ApiException(ErrorCode.SITE_UNAVAILABLE, "站点登录暂不可用，请稍后再试");
        }
    }

    private long findOrCreateMapping(String identitySource, SiteTokenResponse site, String tokenHash,
                                     LocalDateTime tokenExpiresAt, LocalDateTime now) {
        var existing = identityRepository.findMapping(identitySource, site.externalUserId());
        if (existing.isPresent()) {
            SiteIdentityRepository.SiteIdentityMapping mapping = existing.get();
            if (!mapping.active()) {
                throw new ApiException(ErrorCode.USER_DISABLED,
                        "该账号已被站点管理员禁用，无法登录客户端");
            }
            identityRepository.updateSiteToken(mapping.userPk(), tokenHash, tokenExpiresAt, now);
            return mapping.userPk();
        }
        long created = createSiteUser(identitySource, site, tokenHash, tokenExpiresAt, now);
        log.info("site identity mapped: source={} user={}", identitySource, site.externalUserId());
        return created;
    }

    /**
     * 新建映射账号。并发下两个请求同时走到这里时，uk_identity 兜底：
     * 后到的 INSERT 撞唯一键，重查一遍拿到同一行（幂等，不报错）。
     */
    private long createSiteUser(String identitySource, SiteTokenResponse site, String tokenHash,
                                LocalDateTime tokenExpiresAt, LocalDateTime now) {
        String username = candidateUsername(site.externalUserId());
        // 站点账号没有口令，塞一个不可能被猜中的随机摘要占位（列 NOT NULL）。
        String unusablePasswordHash = passwordEncoder.encode(randomHex(32));
        try {
            return identityRepository.insertSiteUser(idGenerator.nextUserId(), username,
                    unusablePasswordHash, identitySource, site.externalUserId(),
                    tokenHash, tokenExpiresAt, now);
        } catch (DuplicateKeyException ex) {
            // 并发首登：映射行已被并发请求建出，直接复用。
            return identityRepository.findMapping(identitySource, site.externalUserId())
                    .orElseThrow(() -> ex)
                    .userPk();
        }
    }

    /**
     * 平台用户名给站点用户用：{@code site_<external_user_id>}。
     * 撞上已有人类用户名（前缀只是约定，不设保留字）就加随机后缀——
     * 映射锚是 (identity_source, external_user_id)，用户名不是身份的一部分，随机后缀无害。
     */
    private String candidateUsername(String externalUserId) {
        String base = USERNAME_PREFIX + externalUserId;
        if (base.length() > USERNAME_MAX) {
            base = base.substring(0, USERNAME_MAX);
        }
        String candidate = base;
        while (userRepository.existsByUsername(candidate)) {
            candidate = base + "_" + randomHex(3);
            if (candidate.length() > USERNAME_MAX) {
                candidate = candidate.substring(0, USERNAME_MAX - 4) + randomHex(2);
            }
        }
        return candidate;
    }

    private static String randomHex(int bytes) {
        byte[] buf = new byte[bytes];
        new SecureRandom().nextBytes(buf);
        return HexFormat.of().formatHex(buf);
    }
}
