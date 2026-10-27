package com.otaku.device;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.time.LocalDateTime;
import java.time.ZoneOffset;

/**
 * 设备令牌表清理：清掉"已失效且超过保留期"的行。
 *
 * 为什么需要：令牌失效时**不删记录**（方案 §4.3 第 4 点），保留是为了排查
 * （"我为什么收不到推送"这类问题要看 disabled_at）。
 * 但也不能永远留着——保留 30 天，兼顾排查与表体积。
 *
 * 范式照 {@code SessionCleanupJob}。
 */
@Component
public class DeviceCleanupJob {

    private static final Logger log = LoggerFactory.getLogger(DeviceCleanupJob.class);

    /** 失效记录的保留天数。 */
    static final int RETENTION_DAYS = 30;

    private final DeviceRepository repository;

    public DeviceCleanupJob(DeviceRepository repository) {
        this.repository = repository;
    }

    /** 每天 04:45 UTC 执行；与会话清理（04:30）错开，避免同一分钟抢资源。 */
    @Scheduled(cron = "0 45 4 * * *", zone = "UTC")
    public void purge() {
        int deleted = purge(LocalDateTime.now(ZoneOffset.UTC));
        if (deleted > 0) {
            log.info("清理已失效的设备令牌 {} 条", deleted);
        }
    }

    /** 抽出来便于单测直接调用，不必等定时器。 */
    int purge(LocalDateTime now) {
        return repository.purgeDisabledBefore(now.minusDays(RETENTION_DAYS));
    }
}
