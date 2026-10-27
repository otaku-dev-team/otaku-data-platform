package com.otaku.device;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.time.LocalDateTime;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 设备令牌清理任务：失效记录保留 30 天后清除。
 *
 * <p>「失效不删」是为了排查，所以清理必须有保留期，不能一见 disabled_at 就删。
 */
class DeviceCleanupJobTest {

    @Test
    @DisplayName("清理的是保留期之前的失效记录")
    void purgesOnlyOldDisabledRows() {
        DeviceRepository repository = mock(DeviceRepository.class);
        when(repository.purgeDisabledBefore(any(LocalDateTime.class))).thenReturn(3);
        DeviceCleanupJob job = new DeviceCleanupJob(repository);

        LocalDateTime now = LocalDateTime.of(2026, 10, 25, 12, 0, 0);
        int deleted = job.purge(now);

        assertThat(deleted).isEqualTo(3);
        ArgumentCaptor<LocalDateTime> before = ArgumentCaptor.forClass(LocalDateTime.class);
        verify(repository).purgeDisabledBefore(before.capture());
        // 保留期 30 天：清理的是 30 天前就失效的。
        assertThat(before.getValue()).isEqualTo(now.minusDays(30));
    }
}
