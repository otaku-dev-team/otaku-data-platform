package com.otaku.config;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 令牌桶的边界行为（Issue #188 形态 A）。
 *
 * <p>不连库、不起 Spring：这里验的是"第 N 次该不该放行"与"时间过去后能不能恢复"，
 * 都是纯算术，用注入的时间戳测比 sleep 稳定得多。
 */
class IpRateLimiterTest {

    private final IpRateLimiter limiter = new IpRateLimiter();

    @Test
    @DisplayName("桶容量用完即拒；过一段时间按速率补充")
    void burstThenRefill() {
        long t0 = 0L;
        assertThat(limiter.tryAcquire("ip|public", 60, 2, t0)).isTrue();
        assertThat(limiter.tryAcquire("ip|public", 60, 2, t0)).isTrue();
        assertThat(limiter.tryAcquire("ip|public", 60, 2, t0))
                .as("容量 2，第三次必须拒").isFalse();

        // 60/min = 1 个/秒；1 秒后补 1 个
        long oneSecondLater = t0 + TimeUnit.SECONDS.toNanos(1);
        assertThat(limiter.tryAcquire("ip|public", 60, 2, oneSecondLater)).isTrue();
        assertThat(limiter.tryAcquire("ip|public", 60, 2, oneSecondLater)).isFalse();
    }

    @Test
    @DisplayName("不同桶互不影响：刷封面不该吃掉列表额度")
    void bucketsAreIndependent() {
        long t0 = 0L;
        assertThat(limiter.tryAcquire("ip|cover", 60, 1, t0)).isTrue();
        assertThat(limiter.tryAcquire("ip|cover", 60, 1, t0)).isFalse();
        assertThat(limiter.tryAcquire("ip|public", 60, 1, t0))
                .as("封面桶耗尽了，公共桶仍然满").isTrue();
    }

    @Test
    @DisplayName("条目数有上限：海量 IP 不会把内存吃爆")
    void entriesAreBounded() {
        long t0 = 0L;
        for (int i = 0; i < IpRateLimiter.MAX_ENTRIES + 50; i++) {
            limiter.tryAcquire("ip" + i + "|public", 60, 1, t0);
        }
        assertThat(limiter.size()).isEqualTo(IpRateLimiter.MAX_ENTRIES);
    }
}
