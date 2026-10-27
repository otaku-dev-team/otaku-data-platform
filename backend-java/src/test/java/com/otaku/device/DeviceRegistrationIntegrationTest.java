package com.otaku.device;

import com.otaku.common.ApiException;
import com.otaku.common.ErrorCode;
import com.otaku.device.dto.DeviceDto;
import com.otaku.device.dto.DeviceRegistrationRequest;
import com.otaku.user.UserRecord;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * 设备令牌登记的行为约束。
 *
 * <p>为什么必须连真库：验的是 {@code uk_device_token} 这个唯一键 +
 * 「token 跨账号转移」时的 UPDATE 顺序，全是 MySQL 方言；
 * Mock 掉仓储等于只测了 Java 分支，H2 也不支持这套外键与唯一键语义。
 *
 * <p>没有 {@code IT_DB_PORT} 时整类跳过（普通 {@code mvn test} 不需要数据库），
 * CI 由 workflow 注入 {@code IT_DB_PORT=3306} 真跑。
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3307）后重跑")
class DeviceRegistrationIntegrationTest {

    private static final String USER_PREFIX = "it-dev-user-";

    @Autowired
    private DeviceService service;

    @Autowired
    private JdbcTemplate jdbc;

    @Autowired
    private com.fasterxml.jackson.databind.ObjectMapper objectMapper;

    private UserRecord alice;
    private UserRecord bob;

    @BeforeEach
    void setUp() {
        alice = createUser("alice");
        bob = createUser("bob");
    }

    @AfterEach
    void cleanUp() {
        // 有外键指向 app_user，必须先清子表再清用户。
        jdbc.update("DELETE FROM user_device WHERE user_id IN"
                + " (SELECT id FROM app_user WHERE user_id LIKE ?)", USER_PREFIX + "%");
        jdbc.update("DELETE FROM app_user WHERE user_id LIKE ?", USER_PREFIX + "%");
    }

    @Test
    @DisplayName("登记后能列出，且响应里没有 token")
    void registerThenList() throws com.fasterxml.jackson.core.JsonProcessingException {
        DeviceService.RegistrationResult result =
                service.register(alice, request("dev-1", "tok-1"));

        assertThat(result.created()).isTrue();
        assertThat(result.device().deviceId()).isEqualTo("dev-1");
        assertThat(result.device().enabled()).isTrue();

        List<DeviceDto> devices = service.list(alice);
        assertThat(devices).hasSize(1);
        assertThat(devices.get(0).deviceId()).isEqualTo("dev-1");
        // token 是凭据：响应体里不能有。DeviceDto 压根没有 token 字段（record 编译期就保证了），
        // 这里再钉一层「JSON 序列化后不含 token 键」，防有人后来加字段。
        assertThat(objectMapper.writeValueAsString(devices.get(0)))
                .doesNotContain("token");
    }

    @Test
    @DisplayName("同一 device_id 重复登记是更新而不是新建")
    void registerSameDeviceTwiceUpdates() {
        service.register(alice, request("dev-1", "tok-1"));
        DeviceService.RegistrationResult second =
                service.register(alice, request("dev-1", "tok-2"));

        assertThat(second.created()).isFalse();
        assertThat(service.list(alice)).hasSize(1);
        // token 确实换成了新的那个。
        assertThat(jdbc.queryForObject(
                "SELECT token FROM user_device WHERE device_id = ?", String.class, "dev-1"))
                .isEqualTo("tok-2");
    }

    @Test
    @DisplayName("token 跨账号转移：别个账号注册同一 token 后，本账号那条立即失效")
    void tokenTransfersAcrossAccounts() {
        service.register(alice, request("dev-1", "shared-token"));

        // Bob 用同一台设备（同一 token）注册。
        service.register(bob, request("dev-1", "shared-token"));

        // Bob 的那条是活的。
        assertThat(service.list(bob)).hasSize(1);
        assertThat(service.list(bob).get(0).enabled()).isTrue();
        // Alice 的那条必须失效——否则她退出登录后，这台设备仍会收到她的推送，
        // 而通知会直接显示在锁屏上。
        assertThat(enabledOf(alice, "dev-1")).isFalse();
        assertThat(disabledAtOf(alice, "dev-1")).isNotNull();
        // 而且原 token 不能留在库里——凭据不留存。旧行的 token 被换成不可逆占位值，
        // 既释放了唯一键（否则 Bob 注册时 DuplicateKey），又推不回原 token。
        assertThat(tokenOf(alice, "dev-1"))
                .startsWith("revoked:")
                .doesNotContain("shared-token");
    }

    @Test
    @DisplayName("设备数超上限返回 409 DEVICE_LIMIT_EXCEEDED")
    void deviceLimitExceeded() {
        for (int i = 0; i < DeviceService.MAX_DEVICES_PER_USER; i++) {
            service.register(alice, request("dev-" + i, "tok-" + i));
        }

        assertThatThrownBy(() -> service.register(alice, request("dev-extra", "tok-extra")))
                .isInstanceOf(ApiException.class)
                .satisfies(ex -> assertThat(((ApiException) ex).code())
                        .isEqualTo(ErrorCode.DEVICE_LIMIT_EXCEEDED));
    }

    @Test
    @DisplayName("更新既有设备不占新名额")
    void updatingExistingDeviceDoesNotCountAgainstLimit() {
        for (int i = 0; i < DeviceService.MAX_DEVICES_PER_USER; i++) {
            service.register(alice, request("dev-" + i, "tok-" + i));
        }

        // 同一台设备再登记一次（token 轮换），不该因为到上限而失败。
        DeviceService.RegistrationResult again =
                service.register(alice, request("dev-0", "tok-rotated"));
        assertThat(again.created()).isFalse();
    }

    @Test
    @DisplayName("解绑幂等：删掉不存在的设备也不报错")
    void removeIsIdempotent() {
        service.register(alice, request("dev-1", "tok-1"));

        service.remove(alice, "dev-1");
        service.remove(alice, "dev-1");

        assertThat(service.list(alice)).isEmpty();
    }

    @Test
    @DisplayName("别人的设备解绑不掉")
    void cannotRemoveOthersDevice() {
        service.register(alice, request("dev-1", "tok-1"));

        service.remove(bob, "dev-1");

        assertThat(service.list(alice)).hasSize(1);
    }

    @Test
    @DisplayName("参数不合法时 400")
    void rejectsBadInput() {
        assertBadRequest(new DeviceRegistrationRequest(null, "android", "fcm", "tok", null, null));
        assertBadRequest(new DeviceRegistrationRequest("dev", null, "fcm", "tok", null, null));
        assertBadRequest(new DeviceRegistrationRequest("dev", "android", "unknown-provider", "tok", null, null));
        assertBadRequest(new DeviceRegistrationRequest("dev", "android", "fcm", "  ", null, null));
    }

    @Test
    @DisplayName("平台与 provider 归一化为小写")
    void normalizesCase() {
        DeviceService.RegistrationResult result =
                service.register(alice, new DeviceRegistrationRequest(
                        "dev-1", "Android", "FCM", "tok-1", "1.0.0+1", null));

        assertThat(result.device().platform()).isEqualTo("android");
        assertThat(result.device().provider()).isEqualTo("fcm");
    }

    // ---------------------------------------------------------------- helpers

    private void assertBadRequest(DeviceRegistrationRequest request) {
        assertThatThrownBy(() -> service.register(alice, request))
                .isInstanceOf(ApiException.class)
                .satisfies(ex -> assertThat(((ApiException) ex).code())
                        .isEqualTo(ErrorCode.BAD_REQUEST));
    }

    private DeviceRegistrationRequest request(String deviceId, String token) {
        return new DeviceRegistrationRequest(deviceId, "android", "fcm", token, "1.4.0+12", null);
    }

    private UserRecord createUser(String suffix) {
        String userId = USER_PREFIX + suffix + "-" + UUID.randomUUID().toString().substring(0, 8);
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        // JdbcTemplate 用 ? 占位符——具名参数是 NamedParameterJdbcTemplate 的语法。
        jdbc.update("""
                        INSERT INTO app_user (user_id, username, password_hash, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                userId, userId, "not-a-real-hash", now, now);
        Long id = jdbc.queryForObject(
                "SELECT id FROM app_user WHERE user_id = ?", Long.class, userId);
        return new UserRecord(id, userId, userId, "not-a-real-hash", null,
                UserRecord.STATUS_ACTIVE, now, now, now);
    }

    private boolean enabledOf(UserRecord user, String deviceId) {
        Boolean enabled = jdbc.queryForObject(
                "SELECT enabled FROM user_device WHERE user_id = ? AND device_id = ?",
                Boolean.class, user.id(), deviceId);
        return enabled != null && enabled;
    }

    private String tokenOf(UserRecord user, String deviceId) {
        return jdbc.queryForObject(
                "SELECT token FROM user_device WHERE user_id = ? AND device_id = ?",
                String.class, user.id(), deviceId);
    }

    private LocalDateTime disabledAtOf(UserRecord user, String deviceId) {
        return jdbc.queryForObject(
                "SELECT disabled_at FROM user_device WHERE user_id = ? AND device_id = ?",
                LocalDateTime.class, user.id(), deviceId);
    }
}
