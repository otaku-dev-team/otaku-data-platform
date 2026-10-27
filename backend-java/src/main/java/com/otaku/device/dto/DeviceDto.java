package com.otaku.device.dto;

import java.time.Instant;

/**
 * 已登记设备的响应体，字段与 W1.3b 方案 §4.2 一致。
 *
 * <p>**永不含 token**：那是凭据，客户端本来就有，回显只增加泄露面。
 * 排查时用 {@code device_id} + {@code platform} 定位即可。
 */
public record DeviceDto(
        String deviceId,
        String platform,
        String provider,
        Boolean enabled,
        Instant createdAt,
        Instant updatedAt
) {
}
