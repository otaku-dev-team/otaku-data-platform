package com.otaku.ugc;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.time.LocalDateTime;
import java.time.ZoneOffset;

/**
 * 评论留存清理：把「撤回超过保留期」的软删行物理删除。
 *
 * <p>为什么需要（docs/ugc-retention-proposal.md §3.1）：软删是为了追溯，但「保留」不等于「永久」——
 * 现在没有清理，等于用户以为删掉了、数据一直在库里，表也只增不减。
 *
 * <p>只清 {@code status='deleted'}。已发布 / 待审 / 已隐藏的评论一条都不动：
 * 那些还有产品意义，清掉等于替站主删内容。
 *
 * <p>保留期是**配置项**（{@code app.ugc.retention.deleted-days}，开发期默认 15），
 * 站点 / 法务给出不同口径时改配置即可，不写死；配成 0 = 不清理。
 *
 * <p>范式照 {@link com.otaku.device.DeviceCleanupJob}。
 */
@Component
public class UgcCleanupJob {

    private static final Logger log = LoggerFactory.getLogger(UgcCleanupJob.class);

    private final UgcRepository repository;
    private final int retentionDays;

    public UgcCleanupJob(UgcRepository repository,
                         @Value("${app.ugc.retention.deleted-days:15}") int retentionDays) {
        this.repository = repository;
        this.retentionDays = retentionDays;
    }

    /** 每天 04:50 UTC；会话清理 04:30、设备令牌 04:45，错开避免同一分钟抢资源。 */
    @Scheduled(cron = "0 50 4 * * *", zone = "UTC")
    public void purge() {
        int deleted = purge(LocalDateTime.now(ZoneOffset.UTC));
        if (deleted > 0) {
            log.info("清理已撤回超过 {} 天的评论 {} 条", retentionDays, deleted);
        }
    }

    /** 抽出来便于单测直接调用，不必等定时器。{@code retentionDays <= 0} = 关闭。 */
    int purge(LocalDateTime now) {
        if (retentionDays <= 0) {
            return 0;
        }
        return repository.purgeDeletedBefore(now.minusDays(retentionDays));
    }
}
