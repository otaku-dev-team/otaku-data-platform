package com.otaku.device;

import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.device.dto.DeviceRegistrationRequest;
import com.otaku.user.UserRecord;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 设备令牌的校验与上限逻辑（不连库）。
 *
 * <p>连库的写入语义在 {@code DeviceRegistrationIntegrationTest}；这里只测
 * 参数校验与「到上限就不再写入」这类纯分支。
 */
class DeviceServiceTest {

    private DeviceRepository repository;
    private DeviceService service;
    private UserRecord user;

    @BeforeEach
    void setUp() {
        repository = mock(DeviceRepository.class);
        service = new DeviceService(repository);
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        user = new UserRecord(7L, "u-1", "alice", "hash", null, UserRecord.STATUS_ACTIVE, now, now, now);
    }

    @Test
    @DisplayName("device_id 为空 → 400")
    void rejectsBlankDeviceId() {
        assertBadRequest(new DeviceRegistrationRequest("  ", "android", "fcm", "tok", null, null));
        assertBadRequest(new DeviceRegistrationRequest(null, "android", "fcm", "tok", null, null));
    }

    @Test
    @DisplayName("token 为空 → 400")
    void rejectsBlankToken() {
        assertBadRequest(new DeviceRegistrationRequest("dev-1", "android", "fcm", "   ", null, null));
    }

    @Test
    @DisplayName("platform / provider 取值不合法 → 400")
    void rejectsUnknownEnum() {
        assertBadRequest(new DeviceRegistrationRequest("dev-1", "symbian", "fcm", "tok", null, null));
        assertBadRequest(new DeviceRegistrationRequest("dev-1", "android", "wechat", "tok", null, null));
    }

    @Test
    @DisplayName("device_id 超长 → 400")
    void rejectsTooLongDeviceId() {
        String tooLong = "d".repeat(65);
        assertBadRequest(new DeviceRegistrationRequest(tooLong, "android", "fcm", "tok", null, null));
    }

    @Test
    @DisplayName("token 超长 → 400")
    void rejectsTooLongToken() {
        String tooLong = "t".repeat(513);
        assertBadRequest(new DeviceRegistrationRequest("dev-1", "android", "fcm", tooLong, null, null));
    }

    @Test
    @DisplayName("到上限时抛 409 DEVICE_LIMIT_EXCEEDED，且不写库")
    void rejectsWhenAtLimit() {
        when(repository.find(anyLong(), any())).thenReturn(Optional.empty());
        when(repository.countActive(anyLong())).thenReturn((long) DeviceService.MAX_DEVICES_PER_USER);

        assertThatThrownBy(() -> service.register(user,
                new DeviceRegistrationRequest("dev-1", "android", "fcm", "tok", null, null)))
                .isInstanceOf(ApiException.class)
                .satisfies(ex -> assertThat(((ApiException) ex).code())
                        .isEqualTo(ErrorCode.DEVICE_LIMIT_EXCEEDED));

        verify(repository, never()).insert(anyLong(), any(), any(), any(), any(), any(),
                org.mockito.ArgumentMatchers.anyBoolean(), any());
    }

    @Test
    @DisplayName("登记成功会触发「别个账号用着同一 token 就失效」")
    void disablesSameTokenOnOtherAccounts() {
        when(repository.find(anyLong(), any())).thenReturn(Optional.empty());
        when(repository.countActive(anyLong())).thenReturn(0L);
        when(repository.find(anyLong(), any())).thenReturn(Optional.empty());
        when(repository.find(anyLong(), eq("dev-1"))).thenReturn(Optional.empty());
        when(repository.findAll(anyLong())).thenReturn(List.of());
        // find(user.id, deviceId) 第二次调用（读回）返回刚插入的行。
        when(repository.find(anyLong(), eq("dev-1")))
                .thenReturn(Optional.empty())
                .thenReturn(Optional.of(record()));

        service.register(user, new DeviceRegistrationRequest(
                "dev-1", "android", "fcm", "shared", "1.0", true));

        ArgumentCaptor<Long> keepUser = ArgumentCaptor.forClass(Long.class);
        verify(repository).releaseTokenExceptUser(eq("shared"), keepUser.capture(), any(LocalDateTime.class));
        assertThat(keepUser.getValue()).isEqualTo(7L);
    }

    private void assertBadRequest(DeviceRegistrationRequest request) {
        assertThatThrownBy(() -> service.register(user, request))
                .isInstanceOf(ApiException.class)
                .satisfies(ex -> assertThat(((ApiException) ex).code())
                        .isEqualTo(ErrorCode.BAD_REQUEST));
    }

    private static DeviceRecord record() {
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        return new DeviceRecord(1L, 7L, "dev-1", "android", "fcm", "shared", "1.0", true, now, now, null);
    }
}
