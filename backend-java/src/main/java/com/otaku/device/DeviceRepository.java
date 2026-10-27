package com.otaku.device;

import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;

/**
 * 推送设备令牌的读写。
 *
 * <p>所有查询都强制带 user_id 条件——个人数据不跨账号可见，和收藏同一口径。
 */
@Repository
public class DeviceRepository {

    private static final String COLUMNS =
            "id, user_id, device_id, platform, provider, token, app_version, "
                    + "enabled, created_at, updated_at, disabled_at";

    private static final RowMapper<DeviceRecord> MAPPER = DeviceRepository::map;

    private final NamedParameterJdbcTemplate jdbc;

    public DeviceRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /** 按 (user_id, device_id) 找——upsert 的键。 */
    public Optional<DeviceRecord> find(long userPk, String deviceId) {
        List<DeviceRecord> rows = jdbc.query(
                "SELECT " + COLUMNS + " FROM user_device WHERE user_id = :userId AND device_id = :deviceId",
                new MapSqlParameterSource().addValue("userId", userPk).addValue("deviceId", deviceId),
                MAPPER);
        return rows.stream().findFirst();
    }

    /** 按 token 找——用于「token 跨账号转移」时定位旧记录。 */
    public Optional<DeviceRecord> findByToken(String token) {
        List<DeviceRecord> rows = jdbc.query(
                "SELECT " + COLUMNS + " FROM user_device WHERE token = :token",
                new MapSqlParameterSource("token", token),
                MAPPER);
        return rows.stream().findFirst();
    }

    public List<DeviceRecord> findAll(long userPk) {
        return jdbc.query(
                "SELECT " + COLUMNS + " FROM user_device WHERE user_id = :userId ORDER BY created_at DESC, id DESC",
                new MapSqlParameterSource("userId", userPk),
                MAPPER);
    }

    /** 已登记（未禁用）的设备数——用于「每账号设备上限」。 */
    public long countActive(long userPk) {
        Long total = jdbc.queryForObject(
                "SELECT COUNT(*) FROM user_device WHERE user_id = :userId AND disabled_at IS NULL",
                new MapSqlParameterSource("userId", userPk),
                Long.class);
        return total == null ? 0 : total;
    }

    public void insert(long userPk, String deviceId, String platform, String provider,
                       String token, String appVersion, boolean enabled, LocalDateTime now) {
        jdbc.update("""
                        INSERT INTO user_device
                            (user_id, device_id, platform, provider, token, app_version,
                             enabled, created_at, updated_at)
                        VALUES (:userId, :deviceId, :platform, :provider, :token, :appVersion,
                                :enabled, :now, :now)
                        """,
                new MapSqlParameterSource()
                        .addValue("userId", userPk)
                        .addValue("deviceId", deviceId)
                        .addValue("platform", platform)
                        .addValue("provider", provider)
                        .addValue("token", token)
                        .addValue("appVersion", appVersion)
                        .addValue("enabled", enabled ? 1 : 0)
                        .addValue("now", now));
    }

    /**
     * 更新同一 (user_id, device_id) 的令牌与元信息。
     *
     * <p>token 变了就重新启用（disabled_at 清空）：provider 轮换出新令牌说明它又活了。
     */
    public void update(long userPk, String deviceId, String platform, String provider,
                       String token, String appVersion, boolean enabled, LocalDateTime now) {
        jdbc.update("""
                        UPDATE user_device
                           SET platform = :platform,
                               provider = :provider,
                               token = :token,
                               app_version = :appVersion,
                               enabled = :enabled,
                               disabled_at = NULL,
                               updated_at = :now
                         WHERE user_id = :userId AND device_id = :deviceId
                        """,
                new MapSqlParameterSource()
                        .addValue("platform", platform)
                        .addValue("provider", provider)
                        .addValue("token", token)
                        .addValue("appVersion", appVersion)
                        .addValue("enabled", enabled ? 1 : 0)
                        .addValue("now", now)
                        .addValue("userId", userPk)
                        .addValue("deviceId", deviceId));
    }

    /**
     * 把别处（通常是另一个账号）用着这个 token 的记录**让出**。
     *
     * <p>**这是 token 跨账号转移的落点**：同一台设备换账号登录时，新账号注册同一个
     * token，旧账号那条必须失效——否则前一个用户退出登录后，这台设备仍会收到他的推送，
     * 而通知会直接显示在锁屏上。
     *
     * <p>为什么是「改 token 值」而不只是「置 disabled」：{@code uk_device_token} 是
     * 全局唯一键，新账号 INSERT 时旧行还占着这个 token 就会 DuplicateKey。
     * 所以旧行的 token 必须**真正让出**。
     *
     * <p>让出的方式是换成不可逆的占位值（{@code revoked:} + 原 token 的 SHA-256 摘要前 32 位）：
     * - 唯一键释放，新账号能注册同一个 token；
     * - **原凭据不在库里留存**——占位值推不回原 token；
     * - 行还在，{@code disabled_at} 记着失效时刻——保留可排查痕迹，
     *   与「provider 判失效也不删记录」是同一条口径。
     */
    public int releaseTokenExceptUser(String token, long keepUserPk, LocalDateTime now) {
        return jdbc.update("""
                        UPDATE user_device
                           SET enabled = 0,
                               disabled_at = :now,
                               updated_at = :now,
                               token = CONCAT('revoked:', SUBSTRING(SHA2(:token, 256), 1, 32))
                         WHERE token = :token AND user_id <> :keepUserPk
                        """,
                new MapSqlParameterSource()
                        .addValue("token", token)
                        .addValue("keepUserPk", keepUserPk)
                        .addValue("now", now));
    }

    /** 解绑：按 (user_id, device_id) 删。幂等——不存在也返回 0。 */
    public int delete(long userPk, String deviceId) {
        return jdbc.update("DELETE FROM user_device WHERE user_id = :userId AND device_id = :deviceId",
                new MapSqlParameterSource().addValue("userId", userPk).addValue("deviceId", deviceId));
    }

    /**
     * 清理长期禁用的记录（保留期过后）。
     *
     * <p>「失效不删」是为了排查，但也不能永远留着——这是清理任务的落点，
     * 范式照 {@code SessionCleanupJob}。
     */
    public int purgeDisabledBefore(LocalDateTime before) {
        return jdbc.update("DELETE FROM user_device WHERE disabled_at IS NOT NULL AND disabled_at < :before",
                new MapSqlParameterSource("before", before));
    }

    private static DeviceRecord map(ResultSet rs, int rowNum) throws SQLException {
        return new DeviceRecord(
                rs.getLong("id"),
                rs.getLong("user_id"),
                rs.getString("device_id"),
                rs.getString("platform"),
                rs.getString("provider"),
                rs.getString("token"),
                rs.getString("app_version"),
                rs.getBoolean("enabled"),
                rs.getObject("created_at", LocalDateTime.class),
                rs.getObject("updated_at", LocalDateTime.class),
                rs.getObject("disabled_at", LocalDateTime.class));
    }
}
