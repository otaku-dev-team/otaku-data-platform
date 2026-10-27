package com.otaku.device;

import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.device.dto.DeviceDto;
import com.otaku.device.dto.DeviceRegistrationRequest;
import com.otaku.user.UserRecord;
import org.springframework.stereotype.Service;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.Set;

/**
 * 推送设备令牌的登记与解绑，行为对齐 W1.3b 方案 §4.1–§4.3。
 *
 * <p>方案本身尚未生效（红线 1，待三人确认），这里按方案写实现。
 */
@Service
public class DeviceService {

    /** 每账号设备上限（方案 §4.3 第 5 点）：避免无限登记。 */
    static final int MAX_DEVICES_PER_USER = 10;

    private static final int MAX_DEVICE_ID_LENGTH = 64;
    private static final int MAX_TOKEN_LENGTH = 512;
    private static final int MAX_APP_VERSION_LENGTH = 32;

    /** 平台与 provider 的取值是开放集的一部分，但只接受已知值。 */
    private static final Set<String> KNOWN_PLATFORMS = Set.of("android", "windows", "ios");
    private static final Set<String> KNOWN_PROVIDERS = Set.of("fcm", "apns");

    private final DeviceRepository repository;

    public DeviceService(DeviceRepository repository) {
        this.repository = repository;
    }

    /**
     * 登记或更新本设备令牌（upsert）。
     *
     * <p>upsert 键是 {@code (user_id, device_id)}：token 会轮换，device_id 不会。
     *
     * @return 新建时为 true（控制器据此回 201），已存在更新为 false（回 200）
     */
    public RegistrationResult register(UserRecord user, DeviceRegistrationRequest request) {
        if (request == null) {
            throw ApiException.badRequest("缺少请求体");
        }
        String deviceId = requireDeviceId(request.deviceId());
        String platform = requireKnown(request.platform(), KNOWN_PLATFORMS, "platform");
        String provider = requireKnown(request.provider(), KNOWN_PROVIDERS, "provider");
        String token = requireToken(request.token());
        String appVersion = normalizeAppVersion(request.appVersion());
        boolean enabled = request.enabled() == null || request.enabled();

        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        DeviceRecord existing = repository.find(user.id(), deviceId).orElse(null);

        // **先让出 token，再写**：uk_device_token 是全局唯一键，
        // 旧账号那条还占着这个 token 时直接 INSERT 会 DuplicateKey。
        //
        // 不做这一步的后果：前一个用户退出登录后这台设备仍会收到他的推送——
        // 通知会直接显示在锁屏上。
        repository.releaseTokenExceptUser(token, user.id(), now);

        if (existing == null) {
            // 设备上限只对新登记生效；更新既有设备不占新名额。
            if (repository.countActive(user.id()) >= MAX_DEVICES_PER_USER) {
                throw new ApiException(ErrorCode.DEVICE_LIMIT_EXCEEDED,
                        "登记的设备数已达上限（" + MAX_DEVICES_PER_USER + "）");
            }
            repository.insert(user.id(), deviceId, platform, provider, token, appVersion, enabled, now);
        } else {
            repository.update(user.id(), deviceId, platform, provider, token, appVersion, enabled, now);
        }

        DeviceRecord saved = repository.find(user.id(), deviceId).orElseThrow();
        return new RegistrationResult(toDto(saved), existing == null);
    }

    /** 列出本账号已登记的设备（不含 token）。 */
    public List<DeviceDto> list(UserRecord user) {
        return repository.findAll(user.id()).stream().map(DeviceService::toDto).toList();
    }

    /** 解绑本设备。幂等——不存在也成功。 */
    public void remove(UserRecord user, String deviceId) {
        String id = requireDeviceId(deviceId);
        repository.delete(user.id(), id);
    }

    private static DeviceDto toDto(DeviceRecord record) {
        return new DeviceDto(
                record.deviceId(),
                record.platform(),
                record.provider(),
                record.enabled(),
                record.createdAt() == null ? null : record.createdAt().toInstant(ZoneOffset.UTC),
                record.updatedAt() == null ? null : record.updatedAt().toInstant(ZoneOffset.UTC));
    }

    private static String requireDeviceId(String raw) {
        if (raw == null || raw.isBlank()) {
            throw ApiException.badRequest("device_id 不能为空");
        }
        String value = raw.trim();
        if (value.length() > MAX_DEVICE_ID_LENGTH) {
            throw ApiException.badRequest("device_id 长度不能超过 " + MAX_DEVICE_ID_LENGTH);
        }
        return value;
    }

    private static String requireToken(String raw) {
        if (raw == null || raw.isBlank()) {
            throw ApiException.badRequest("token 不能为空");
        }
        String value = raw.trim();
        if (value.length() > MAX_TOKEN_LENGTH) {
            throw ApiException.badRequest("token 长度不能超过 " + MAX_TOKEN_LENGTH);
        }
        return value;
    }

    private static String requireKnown(String raw, Set<String> known, String field) {
        if (raw == null || raw.isBlank()) {
            throw ApiException.badRequest(field + " 不能为空");
        }
        String value = raw.trim().toLowerCase(Locale.ROOT);
        if (!known.contains(value)) {
            throw ApiException.badRequest(field + " 取值不合法：" + raw);
        }
        return value;
    }

    private static String normalizeAppVersion(String raw) {
        if (raw == null || raw.isBlank()) {
            return null;
        }
        String value = raw.trim();
        return value.length() > MAX_APP_VERSION_LENGTH ? value.substring(0, MAX_APP_VERSION_LENGTH) : value;
    }

    /** 登记结果：DTO + 是否新建（控制器据此选 201 / 200）。 */
    public record RegistrationResult(DeviceDto device, boolean created) {
        public RegistrationResult {
            Objects.requireNonNull(device);
        }
    }
}
