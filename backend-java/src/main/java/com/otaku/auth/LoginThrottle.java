package com.otaku.auth;

import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayDeque;
import java.util.Deque;
import java.util.Iterator;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * 登录失败限流（契约 §4.1 推荐：同账号 5 次 / 15 分钟）。
 *
 * 取舍：
 * - **只限流、不锁账号**：窗口滑过即自动恢复，不需要人工解锁（契约明确要求不得锁账号）；
 * - **按用户名计数**，键做小写归一，与 `utf8mb4_0900_ai_ci` 的唯一索引语义一致；
 * - 内存实现，单实例有效；将来多实例部署需换成 Redis 或网关层限流（见 README「已知未做」之外的生产化清单）；
 * - 只统计**失败**，成功登录会清空该账号的失败记录，正常用户不会被误伤；
 * - 校验放在口令比对之前，顺带挡掉暴力试错的 CPU 开销（BCrypt 很贵）。
 *
 * 已知局限：攻击者换着用户名试不会触发（这是"按账号"限流的固有边界，
 * 按 IP 限流需要知道客户端真实 IP，属于网关职责，不在应用层硬编码 X-Forwarded-For）。
 */
@Component
public class LoginThrottle {

    private static final Logger log = LoggerFactory.getLogger(LoginThrottle.class);

    static final int MAX_FAILURES = 5;
    static final Duration WINDOW = Duration.ofMinutes(15);
    /** 表本身的上限，防止被随机用户名撑爆内存。 */
    private static final int MAX_TRACKED_KEYS = 5_000;

    private final Clock clock;
    private final Map<String, Deque<Instant>> failures = new ConcurrentHashMap<>();

    public LoginThrottle() {
        this(Clock.systemUTC());
    }

    LoginThrottle(Clock clock) {
        this.clock = clock;
    }

    /** 超限时抛出 429 + Retry-After；未超限直接返回。 */
    public void checkAllowed(String username) {
        Deque<Instant> marks = failures.get(normalize(username));
        if (marks == null) {
            return;
        }
        synchronized (marks) {
            Instant now = clock.instant();
            dropExpired(marks, now);
            if (marks.size() >= MAX_FAILURES) {
                long elapsed = Duration.between(marks.peekFirst(), now).getSeconds();
                long retryAfter = Math.max(1, WINDOW.getSeconds() - elapsed);
                log.info("登录失败次数超限，暂缓处理：user={} failures={} retryAfter={}s",
                        mask(username), marks.size(), retryAfter);
                throw new ApiException(ErrorCode.RATE_LIMITED,
                        "登录失败次数过多，请在 " + retryAfter + " 秒后重试", (int) retryAfter);
            }
        }
    }

    public void recordFailure(String username) {
        String key = normalize(username);
        Deque<Instant> marks = failures.computeIfAbsent(key, k -> new ArrayDeque<>());
        synchronized (marks) {
            marks.addLast(clock.instant());
        }
        if (failures.size() > MAX_TRACKED_KEYS) {
            purgeStaleKeys();
        }
    }

    /** 登录成功即清空该账号的失败记录。 */
    public void clear(String username) {
        failures.remove(normalize(username));
    }

    int trackedKeys() {
        return failures.size();
    }

    private void purgeStaleKeys() {
        Instant now = clock.instant();
        Iterator<Map.Entry<String, Deque<Instant>>> it = failures.entrySet().iterator();
        while (it.hasNext()) {
            Deque<Instant> marks = it.next().getValue();
            synchronized (marks) {
                dropExpired(marks, now);
                if (marks.isEmpty()) {
                    it.remove();
                }
            }
        }
    }

    private void dropExpired(Deque<Instant> marks, Instant now) {
        Instant cutoff = now.minus(WINDOW);
        while (!marks.isEmpty() && marks.peekFirst().isBefore(cutoff)) {
            marks.pollFirst();
        }
    }

    private static String normalize(String username) {
        return username == null ? "" : username.trim().toLowerCase(Locale.ROOT);
    }

    /** 日志里不打全名，避免把用户输入原样写进日志。 */
    private static String mask(String username) {
        if (username == null || username.length() <= 2) {
            return "**";
        }
        return username.charAt(0) + "***" + username.charAt(username.length() - 1);
    }
}
