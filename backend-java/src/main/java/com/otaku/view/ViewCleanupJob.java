package com.otaku.view;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.time.LocalDateTime;
import java.time.ZoneOffset;

/**
 * 浏览行为表清理：保留 90 天（#401 拍板），超期行每天清一次。
 *
 * <p>为什么要有：这是唯一一张**会随用户活跃度增长**的行为表。画像只吃最近 90 天，
 * 更早的行不再影响任何结果，留着只是让表和备份一天天变大。
 *
 * <p>范式照 {@code SessionCleanupJob} / {@code DeviceCleanupJob}；时间点排到 04:55 UTC，
 * 和其它三个清理任务（04:30 / 04:45 / 04:50）错开，别在同一分钟抢连接。
 */
@Component
public class ViewCleanupJob {

    private static final Logger log = LoggerFactory.getLogger(ViewCleanupJob.class);

    /** 保留天数：与画像的取数窗口一致，改这里等于改画像口径，别只改一边。 */
    static final int RETENTION_DAYS = 90;

    private final ViewRepository repository;

    public ViewCleanupJob(ViewRepository repository) {
        this.repository = repository;
    }

    @Scheduled(cron = "0 55 4 * * *", zone = "UTC")
    public void purge() {
        int deleted = purge(LocalDateTime.now(ZoneOffset.UTC));
        if (deleted > 0) {
            log.info("清理超过 {} 天的浏览记录 {} 条", RETENTION_DAYS, deleted);
        }
    }

    /** 抽出来便于单测直接调用，不必等定时器。 */
    int purge(LocalDateTime now) {
        return repository.purgeBefore(now.minusDays(RETENTION_DAYS));
    }
}
