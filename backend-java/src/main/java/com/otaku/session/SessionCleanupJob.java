package com.otaku.session;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.time.LocalDateTime;
import java.time.ZoneOffset;

/**
 * 会话表清理：每天凌晨清掉"过期或撤销已超过保留期"的行。
 *
 * 为什么需要：`user_session` 一行一次登录，不做清理只增不减；
 * 但也不能删太早——刚过期/刚退出的记录往往还在排查期（比如用户反馈"被踢下线"）。
 * 保留 7 天，兼顾排查与表体积。
 *
 * 30 天有效期 + 7 天保留 = 最长的死行最多存在约 37 天，量级可控。
 */
@Component
public class SessionCleanupJob {

    private static final Logger log = LoggerFactory.getLogger(SessionCleanupJob.class);

    static final int RETENTION_DAYS = 7;

    private final SessionRepository sessionRepository;

    public SessionCleanupJob(SessionRepository sessionRepository) {
        this.sessionRepository = sessionRepository;
    }

    /** 每天 04:30 UTC 执行；时区固定 UTC，避免部署地时区导致跑在业务高峰。 */
    @Scheduled(cron = "0 30 4 * * *", zone = "UTC")
    public void purge() {
        int deleted = purge(LocalDateTime.now(ZoneOffset.UTC));
        if (deleted > 0) {
            log.info("清理过期/撤销会话 {} 条", deleted);
        }
    }

    /** 抽出来便于单测直接调用，不必等定时器。 */
    int purge(LocalDateTime now) {
        return sessionRepository.purgeStale(now.minusDays(RETENTION_DAYS));
    }
}
