package com.otaku.device;

import com.otaku.auth.AuthFilter;
import com.otaku.device.dto.DeviceDto;
import com.otaku.device.dto.DeviceRegistrationRequest;
import com.otaku.user.UserRecord;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestAttribute;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * 推送设备令牌接口，全部需要 Bearer 会话令牌（AuthFilter 统一校验）。
 * 路径与方法对齐 W1.3b 方案 §4.1：
 *
 * POST   /api/me/devices              登记或更新本设备令牌（upsert）
 * GET    /api/me/devices              列出本账号已登记设备（不返回 token）
 * DELETE /api/me/devices/{device_id}  解绑本设备（幂等，204）
 *
 * <p>路径用 {@code /api/me/devices} 而不是 {@code /api/devices}：个人数据已在
 * {@code /api/me/collections} 下有先例；{@code /api/devices} 会被读成
 * 「平台的设备目录」，语义不同。
 */
@RestController
@RequestMapping("/api/me/devices")
public class DeviceController {

    private final DeviceService service;

    public DeviceController(DeviceService service) {
        this.service = service;
    }

    @PostMapping
    public ResponseEntity<DeviceDto> register(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @RequestBody DeviceRegistrationRequest request) {
        DeviceService.RegistrationResult result = service.register(user, request);
        // 新建 201、已存在更新 200——客户端据此知道是不是第一次登记。
        return ResponseEntity.status(result.created() ? HttpStatus.CREATED : HttpStatus.OK)
                .body(result.device());
    }

    @GetMapping
    public List<DeviceDto> list(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user) {
        return service.list(user);
    }

    @DeleteMapping("/{deviceId}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void remove(
            @RequestAttribute(AuthFilter.ATTRIBUTE_USER) UserRecord user,
            @PathVariable("deviceId") String deviceId) {
        service.remove(user, deviceId);
    }
}
