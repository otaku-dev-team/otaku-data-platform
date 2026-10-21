package com.otaku.session;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.time.LocalDateTime;
import java.time.ZoneOffset;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class SessionCleanupJobTest {

    @Test
    @DisplayName("清理截止点 = 当前时间 − 保留天数，不能把刚过期的记录立刻删掉")
    void purgeUsesRetentionWindow() {
        SessionRepository repository = mock(SessionRepository.class);
        when(repository.purgeStale(org.mockito.ArgumentMatchers.any())).thenReturn(3);
        SessionCleanupJob job = new SessionCleanupJob(repository);

        LocalDateTime now = LocalDateTime.of(2026, 10, 21, 4, 30);
        int deleted = job.purge(now);

        assertThat(deleted).isEqualTo(3);
        verify(repository).purgeStale(argThat(cutoff ->
                Duration.between(cutoff, now).toDays() == SessionCleanupJob.RETENTION_DAYS));
    }

    @Test
    @DisplayName("保留期是 7 天（与 30 天有效期配合：死行最多滞留约 37 天）")
    void retentionIsSevenDays() {
        assertThat(SessionCleanupJob.RETENTION_DAYS).isEqualTo(7);
        assertThat(LocalDateTime.now(ZoneOffset.UTC)).isNotNull();
    }

    @Test
    @DisplayName("没有可清理的行时不报错")
    void emptyPurgeIsFine() {
        SessionRepository repository = mock(SessionRepository.class);
        when(repository.purgeStale(org.mockito.ArgumentMatchers.any())).thenReturn(0);
        SessionCleanupJob job = new SessionCleanupJob(repository);

        assertThat(job.purge(LocalDateTime.now(ZoneOffset.UTC))).isZero();
        verify(repository, org.mockito.Mockito.times(1)).purgeStale(org.mockito.ArgumentMatchers.any());
    }
}
