package com.otaku.device.dto;

/**
 * 登记 / 更新设备令牌的请求体，字段与 W1.3b 方案 §4.2 一致。
 *
 * <p>{@code deviceId} 是客户端生成的安装级标识（重装后变），**不是** token：
 * token 会轮换，用它当 upsert 键会在轮换时留下一堆僵尸行。
 *
 * <p>{@code token} 视同凭据：不进日志、不回显。
 */
public record DeviceRegistrationRequest(
        String deviceId,
        String platform,
        String provider,
        String token,
        String appVersion,
        Boolean enabled
) {
}
