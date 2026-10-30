package com.otaku.usage;

import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.usage.dto.UsageDtos.PingRequest;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.time.Clock;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.ZoneId;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;

/**
 * 心跳的入口约束。
 *
 * <p>为什么这个类值得存在：`/api/client/ping` 是**公开、免登录、可写**的。
 * 它的全部价值建立在「表里只有匿名标识」上，所以「install_id 形状不对就拒」不是
 * 输入校验的礼节，而是这条隐私承诺的守门人——有人拿它当任意字段的容器，
 * 这张表立刻变成个人信息表。这条断言必须钉死。
 *
 * <p>用固定时钟而不是 {@code Clock.systemDefaultZone()}：心跳落在哪一天决定日活，
 * 让测试随机器时区漂移的话，凌晨跑 CI 会莫名其妙红。
 */
class UsageServiceTest {

    private static final String VALID = "3f2b8c1a-9d4e-4f6b-8a2c-1e5d7b9c0a3f";

    /** 2026-10-31 03:20（Asia/Shanghai）——挑凌晨，跨时区时最容易暴露日期取错。 */
    private static final Clock CLOCK = Clock.fixed(
            Instant.parse("2026-10-30T19:20:00Z"), ZoneId.of("Asia/Shanghai"));

    private final ClientInstallRepository repository = mock(ClientInstallRepository.class);
    private final UsageService service = new UsageService(repository, CLOCK);

    @Test
    @DisplayName("合法心跳：写一次，日期取注入时钟的当天（不是 UTC 的昨天）")
    void recordsValidPing() {
        service.ping(new PingRequest(VALID, "1.1.4", "android"));

        ArgumentCaptor<LocalDateTime> now = ArgumentCaptor.forClass(LocalDateTime.class);
        ArgumentCaptor<LocalDate> day = ArgumentCaptor.forClass(LocalDate.class);
        verify(repository).recordPing(eq(VALID), eq("1.1.4"), eq("android"),
                now.capture(), day.capture());

        assertThat(now.getValue()).isEqualTo(LocalDateTime.of(2026, 10, 31, 3, 20));
        assertThat(day.getValue()).isEqualTo(LocalDate.of(2026, 10, 31));
    }

    @Test
    @DisplayName("大写 install_id 归一成小写：否则同一台设备会算成两台")
    void lowercasesInstallId() {
        service.ping(new PingRequest(VALID.toUpperCase(), "1.1.4", "android"));

        verify(repository).recordPing(eq(VALID), any(), any(), any(), any());
    }

    @Test
    @DisplayName("不是 UUID → 400，且一行都不写")
    void rejectsNonUuid() {
        // 典型的「想往匿名表里塞个人信息」的形状：手机号、邮箱、IMEI
        for (String bad : new String[]{"13800138000", "a@b.com", "352999999999999",
                "", "3f2b8c1a9d4e4f6b8a2c1e5d7b9c0a3f", null}) {
            assertThatThrownBy(() -> service.ping(new PingRequest(bad, "1.1.4", "android")))
                    .isInstanceOf(ApiException.class)
                    .extracting(e -> ((ApiException) e).code())
                    .isEqualTo(ErrorCode.BAD_REQUEST);
        }
        verify(repository, never()).recordPing(any(), any(), any(), any(), any());
    }

    @Test
    @DisplayName("版本号超长：截断而不是拒绝（附带信息不该让整次心跳失败）")
    void truncatesLongVersion() {
        service.ping(new PingRequest(VALID, "x".repeat(50), "android"));

        ArgumentCaptor<String> version = ArgumentCaptor.forClass(String.class);
        verify(repository).recordPing(eq(VALID), version.capture(), eq("android"), any(), any());
        assertThat(version.getValue()).hasSize(32);
    }

    @Test
    @DisplayName("版本号与平台可空：老客户端不带这两个字段也算一次心跳")
    void allowsMissingOptionalFields() {
        service.ping(new PingRequest(VALID, null, "  "));

        verify(repository).recordPing(eq(VALID), eq(null), eq(null), any(), any());
    }
}
