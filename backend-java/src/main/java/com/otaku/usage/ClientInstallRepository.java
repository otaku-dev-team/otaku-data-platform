package com.otaku.usage;

import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

import java.time.LocalDate;
import java.time.LocalDateTime;

/**
 * 安装级统计的读写（表结构见 {@code V27__client_install.sql}）。
 *
 * <p>两次写入而不是一次事务里的两条语句也考虑过合并成一条存储过程——
 * 不值得：这里是「心跳」路径，量不大，且**丢一天的明细不影响装机数**，
 * 反过来为了原子性引入存储过程会让迁移和排查都变难。
 */
@Repository
public class ClientInstallRepository {

    private final NamedParameterJdbcTemplate jdbc;

    public ClientInstallRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /**
     * 记一次心跳。
     *
     * <p>用 {@code ON DUPLICATE KEY UPDATE} 而不是「先查再写」：并发下两个请求同时
     * 判断「不存在」会双双插入，第二个撞主键报错——而心跳失败对客户端是静默的，
     * 那种偶发失败最难查。
     *
     * <p>{@code VALUES(col)} 在 MySQL 8.0.20+ 被标记为废弃、推荐用行别名，
     * 这里仍用老写法：项目里 8.0 / 8.4 都可能跑，老写法两种都能用，
     * 新写法在 8.0.19 以下直接语法错误。
     */
    public void recordPing(String installId, String appVersion, String platform,
                           LocalDateTime now, LocalDate day) {
        jdbc.update("""
                        INSERT INTO client_install (install_id, first_seen_at, last_seen_at,
                                                    ping_count, app_version, platform)
                        VALUES (:installId, :now, :now, 1, :appVersion, :platform)
                        ON DUPLICATE KEY UPDATE
                            last_seen_at = VALUES(last_seen_at),
                            ping_count   = ping_count + 1,
                            app_version  = VALUES(app_version),
                            platform     = VALUES(platform)
                        """,
                params(installId, appVersion, platform, now, day));

        // 同一天第二次心跳不该再插一行：主键 (install_id, day) 让它自然幂等。
        jdbc.update("""
                        INSERT IGNORE INTO client_active_day (install_id, day)
                        VALUES (:installId, :day)
                        """,
                params(installId, appVersion, platform, now, day));
    }

    private static MapSqlParameterSource params(String installId, String appVersion,
                                               String platform, LocalDateTime now,
                                               LocalDate day) {
        return new MapSqlParameterSource()
                .addValue("installId", installId)
                .addValue("appVersion", appVersion)
                .addValue("platform", platform)
                .addValue("now", now)
                .addValue("day", day);
    }
}
