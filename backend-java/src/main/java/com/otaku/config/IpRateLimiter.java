package com.otaku.config;

import org.springframework.stereotype.Component;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 按 IP 的令牌桶（Issue #188 形态 A：先做自我保护，不做站点身份）。
 *
 * <p>为什么是令牌桶而不是"每分钟计数"：计数窗口在边界会放过两倍流量
 * （59 秒 600 次 + 61 秒 600 次），而令牌桶允许短时突发、长期仍受限——
 * 对「App 打开首页并发拉 20 个封面」这种正常行为和「脚本刷图床」都有合理解释。
 *
 * <p>容量上限与条目上限都是**防内存被打爆**的：IP 可以伪造/海量，
 * 不设界就是给攻击者一个 OOM 开关（每个 IP 一条记录也一样能撑爆）。
 * 条目按 LRU 淘汰——被淘汰的 IP 下次重新从满桶开始，这在低配额下等价于"暂时放行一次"，
 * 比"无限增长"安全得多。
 */
@Component
public class IpRateLimiter {

    /** 条目上限：10k 个不同 IP。超过就淘汰最久未用的（见类注释）。 */
    static final int MAX_ENTRIES = 10_000;

    private final Map<String, Bucket> buckets = Collections.synchronizedMap(
            new LinkedHashMap<>(256, 0.75f, true) {
                @Override
                protected boolean removeEldestEntry(Map.Entry<String, Bucket> eldest) {
                    return size() > MAX_ENTRIES;
                }
            });

    /**
     * 尝试取一个令牌。
     *
     * @param key        IP + 桶名（作品/封面分开计，否则刷图会把正常浏览额度吃光）
     * @param perMinute  每分钟补充的令牌数
     * @param burst      桶容量（允许的瞬时突发）
     * @param nowNanos   当前时间（测试可注入，避免 sleep）
     */
    public boolean tryAcquire(String key, int perMinute, int burst, long nowNanos) {
        Bucket bucket = buckets.computeIfAbsent(key, k -> new Bucket(burst, nowNanos));
        return bucket.tryAcquire(perMinute, burst, nowNanos);
    }

    /** 仅供测试与排查：当前记录的 IP 数。 */
    int size() {
        return buckets.size();
    }

    /** 清空（测试用：同一 IP 跨用例会互相影响）。 */
    public void reset() {
        buckets.clear();
    }

    private static final class Bucket {
        private double tokens;
        private long lastRefillNanos;

        Bucket(int capacity, long nowNanos) {
            this.tokens = capacity;
            this.lastRefillNanos = nowNanos;
        }

        synchronized boolean tryAcquire(int perMinute, int capacity, long nowNanos) {
            double perNano = perMinute / 60_000_000_000.0;
            long elapsed = Math.max(0, nowNanos - lastRefillNanos);
            if (elapsed > 0) {
                tokens = Math.min(capacity, tokens + elapsed * perNano);
                lastRefillNanos = nowNanos;
            }
            if (tokens < 1.0) {
                return false;
            }
            tokens -= 1.0;
            return true;
        }
    }
}
