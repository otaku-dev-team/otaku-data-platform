package com.otaku.console;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.time.OffsetDateTime;
import java.time.ZoneOffset;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 同步运行的三态判定。
 *
 * <p>「没有收尾时间」必须优先于「有拒收」：进程被杀 / 提交后没等到结果时，
 * 这次运行的 rejected 可能是 0，只看 rejected 就会把它显示成"成功"——
 * 站主看到"同步正常"，而实际上一次都没跑完。这个错误曾经真实存在于同步脚本的判定里
 * （{@code check_run_report.py} 的 failed_pages 与 server_error_items 分开算）。
 */
class ConsoleSyncRunStatusTest {

    @Test
    @DisplayName("有收尾、无拒收 → ok")
    void finishedCleanIsOk() {
        assertThat(ConsoleSyncService.runStatus(at(10), 0)).isEqualTo("ok");
    }

    @Test
    @DisplayName("有收尾、有拒收 → partial（能看见，才谈得上补齐）")
    void finishedWithRejectionsIsPartial() {
        assertThat(ConsoleSyncService.runStatus(at(10), 7)).isEqualTo("partial");
    }

    @Test
    @DisplayName("没有收尾 → failed，即使 rejected 是 0")
    void unfinishedIsFailedEvenWithoutRejections() {
        assertThat(ConsoleSyncService.runStatus(null, 0)).isEqualTo("failed");
    }

    @Test
    @DisplayName("没有收尾且有拒收 → failed（更严重的那个说了算）")
    void unfinishedWithRejectionsIsFailed() {
        assertThat(ConsoleSyncService.runStatus(null, 3)).isEqualTo("failed");
    }

    private static OffsetDateTime at(int minutesAgo) {
        return OffsetDateTime.now(ZoneOffset.UTC).minusMinutes(minutesAgo);
    }
}
