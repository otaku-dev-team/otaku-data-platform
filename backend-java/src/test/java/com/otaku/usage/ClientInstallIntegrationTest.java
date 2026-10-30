package com.otaku.usage;

import com.otaku.usage.dto.UsageDtos.PingRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;

import java.sql.Date;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 心跳落库的行为约束（连真库）。
 *
 * <p>为什么必须连 MySQL：验的是 {@code ON DUPLICATE KEY UPDATE} 的累加语义 +
 * {@code (install_id, day)} 的幂等，全是方言；Mock 掉仓储等于只测了 Java 分支。
 *
 * <p>最要紧的两条：
 * <ul>
 *   <li>{@code first_seen_at} 在第二次心跳时必须**不动**——它等于装机时间，
 *       被覆盖的话「留存」这个指标就永远算错，而且错得没有声音；</li>
 *   <li>同一天两次心跳只产生**一行**日活，否则日活会随启动次数膨胀。</li>
 * </ul>
 *
 * <p>没有 {@code IT_DB_PORT} 时整类跳过（普通 {@code mvn test} 不需要数据库）。
 */
@SpringBootTest
@ActiveProfiles("it")
@EnabledIfEnvironmentVariable(
        named = "IT_DB_PORT",
        matches = "\\d+",
        disabledReason = "集成测试需要真实 MySQL：设置 IT_DB_PORT（如 3310）后重跑")
class ClientInstallIntegrationTest {

    @Autowired
    private UsageService service;

    @Autowired
    private JdbcTemplate jdbc;

    private final String installId = UUID.randomUUID().toString();

    @AfterEach
    void cleanup() {
        jdbc.update("DELETE FROM client_active_day WHERE install_id = ?", installId);
        jdbc.update("DELETE FROM client_install WHERE install_id = ?", installId);
    }

    @Test
    @DisplayName("首次心跳：一行安装记录 + 一行日活，first_seen == last_seen")
    void firstPingCreatesRows() {
        service.ping(new PingRequest(installId, "1.1.4", "android"));

        var install = jdbc.queryForMap(
                "SELECT ping_count, app_version, platform, first_seen_at, last_seen_at "
                        + "FROM client_install WHERE install_id = ?", installId);
        assertThat(install.get("ping_count")).isEqualTo(1L);
        assertThat(install.get("app_version")).isEqualTo("1.1.4");
        assertThat(install.get("platform")).isEqualTo("android");
        assertThat(install.get("first_seen_at")).isEqualTo(install.get("last_seen_at"));

        assertThat(activeDays()).containsExactly(LocalDate.now());
    }

    @Test
    @DisplayName("同日第二次心跳：ping_count 累加、first_seen 不动、日活仍只有一行")
    void secondPingSameDay() {
        service.ping(new PingRequest(installId, "1.1.4", "android"));
        Object firstSeen = jdbc.queryForObject(
                "SELECT first_seen_at FROM client_install WHERE install_id = ?",
                Object.class, installId);

        service.ping(new PingRequest(installId, "1.1.5", "android"));

        var install = jdbc.queryForMap(
                "SELECT ping_count, app_version, first_seen_at FROM client_install "
                        + "WHERE install_id = ?", installId);
        assertThat(install.get("ping_count")).isEqualTo(2L);
        // 版本跟着最新一次心跳走：老版本用户升级后，分布要能反映出来
        assertThat(install.get("app_version")).isEqualTo("1.1.5");
        // 装机时间不能被覆盖——这条错了，留存就永远算不对且没有任何报错
        assertThat(install.get("first_seen_at")).isEqualTo(firstSeen);

        assertThat(activeDays()).containsExactly(LocalDate.now());
    }

    @Test
    @DisplayName("不同 install_id 互不影响（重装后是新的一台）")
    void differentInstallsAreSeparate() {
        String other = UUID.randomUUID().toString();
        try {
            service.ping(new PingRequest(installId, "1.1.4", "android"));
            service.ping(new PingRequest(other, "1.1.4", "android"));

            assertThat(jdbc.queryForObject(
                    "SELECT COUNT(*) FROM client_install WHERE install_id IN (?, ?)",
                    Integer.class, installId, other)).isEqualTo(2);
            // 今天的日活是 2，不是 1
            assertThat(jdbc.queryForObject(
                    "SELECT COUNT(*) FROM client_active_day WHERE day = ? AND install_id IN (?, ?)",
                    Integer.class, LocalDate.now(), installId, other)).isEqualTo(2);
        } finally {
            jdbc.update("DELETE FROM client_active_day WHERE install_id = ?", other);
            jdbc.update("DELETE FROM client_install WHERE install_id = ?", other);
        }
    }

    private List<LocalDate> activeDays() {
        return jdbc.queryForList(
                        "SELECT day FROM client_active_day WHERE install_id = ? ORDER BY day",
                        Date.class, installId)
                .stream().map(Date::toLocalDate).toList();
    }
}
