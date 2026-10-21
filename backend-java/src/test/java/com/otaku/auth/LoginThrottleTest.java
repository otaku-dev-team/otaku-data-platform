package com.otaku.auth;

import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** 登录失败限流：5 次 / 15 分钟，只限流不锁号，成功即清零。 */
class LoginThrottleTest {

    private final MutableClock clock = new MutableClock(Instant.parse("2026-10-21T04:00:00Z"));
    private final LoginThrottle throttle = new LoginThrottle(clock);

    @Test
    @DisplayName("失败 4 次仍放行，第 5 次之后开始 429")
    void blocksAfterFiveFailures() {
        for (int i = 0; i < 4; i++) {
            throttle.recordFailure("alice");
        }
        assertThatCode(() -> throttle.checkAllowed("alice")).doesNotThrowAnyException();

        throttle.recordFailure("alice");
        assertThatThrownBy(() -> throttle.checkAllowed("alice"))
                .isInstanceOf(ApiException.class)
                .satisfies(ex -> {
                    ApiException api = (ApiException) ex;
                    assertThat(api.code()).isEqualTo(ErrorCode.RATE_LIMITED);
                    assertThat(api.retryAfterSeconds()).isNotNull().isGreaterThan(0);
                });
    }

    @Test
    @DisplayName("窗口滑过后自动恢复，不需要人工解锁")
    void recoversAfterWindow() {
        for (int i = 0; i < 5; i++) {
            throttle.recordFailure("alice");
        }
        assertThatThrownBy(() -> throttle.checkAllowed("alice")).isInstanceOf(ApiException.class);

        clock.advance(Duration.ofMinutes(15).plusSeconds(1));
        assertThatCode(() -> throttle.checkAllowed("alice")).doesNotThrowAnyException();
    }

    @Test
    @DisplayName("成功登录会清空失败记录，正常用户不被误伤")
    void successClearsFailures() {
        for (int i = 0; i < 4; i++) {
            throttle.recordFailure("alice");
        }
        throttle.clear("alice");
        for (int i = 0; i < 4; i++) {
            throttle.recordFailure("alice");
        }
        assertThatCode(() -> throttle.checkAllowed("alice")).doesNotThrowAnyException();
    }

    @Test
    @DisplayName("用户名大小写不敏感：Alice 的失败会挡住 alice")
    void usernameIsCaseInsensitive() {
        for (int i = 0; i < 5; i++) {
            throttle.recordFailure("Alice");
        }
        assertThatThrownBy(() -> throttle.checkAllowed("alice")).isInstanceOf(ApiException.class);
    }

    @Test
    @DisplayName("不同账号互不影响")
    void accountsAreIsolated() {
        for (int i = 0; i < 5; i++) {
            throttle.recordFailure("alice");
        }
        assertThatCode(() -> throttle.checkAllowed("bob")).doesNotThrowAnyException();
    }

    @Test
    @DisplayName("Retry-After 不超过一个窗口，且随时间递减")
    void retryAfterShrinks() {
        for (int i = 0; i < 5; i++) {
            throttle.recordFailure("alice");
        }
        int first = retryAfter("alice");
        clock.advance(Duration.ofMinutes(5));
        int second = retryAfter("alice");

        assertThat(first).isBetween(1, (int) LoginThrottle.WINDOW.getSeconds());
        assertThat(second).isLessThan(first);
    }

    private int retryAfter(String username) {
        try {
            throttle.checkAllowed(username);
            throw new AssertionError("预期被限流");
        } catch (ApiException ex) {
            return ex.retryAfterSeconds();
        }
    }

    /** 可手动推进的时钟，避免测试里真的 sleep 15 分钟。 */
    private static final class MutableClock extends Clock {

        private Instant now;

        private MutableClock(Instant now) {
            this.now = now;
        }

        void advance(Duration duration) {
            now = now.plus(duration);
        }

        @Override
        public ZoneId getZone() {
            return ZoneOffset.UTC;
        }

        @Override
        public Clock withZone(ZoneId zone) {
            return this;
        }

        @Override
        public Instant instant() {
            return now;
        }
    }
}
