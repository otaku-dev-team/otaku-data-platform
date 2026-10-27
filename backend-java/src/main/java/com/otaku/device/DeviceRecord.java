package com.otaku.device;

import java.time.LocalDateTime;

/**
 * user_device 的一行。
 *
 * <p>{@code token} 视同凭据：不出现在任何 DTO 里，也不进日志。
 */
public record DeviceRecord(
        Long id,
        Long userId,
        String deviceId,
        String platform,
        String provider,
        String token,
        String appVersion,
        boolean enabled,
        LocalDateTime createdAt,
        LocalDateTime updatedAt,
        LocalDateTime disabledAt
) {
}
