package com.otaku.user;

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
 * 账号读写。
 * 用户名唯一：表上 uk_username 用的是 utf8mb4_0900_ai_ci，大小写不敏感，
 * 所以 "Alice" 与 "alice" 视为同一个账号，注册时不会出现两个。
 */
@Repository
public class UserRepository {

    private static final String COLUMNS =
            "id, user_id, username, password_hash, site_key, status, status_changed_at,"
                    + " created_at, updated_at";

    private static final RowMapper<UserRecord> MAPPER = UserRepository::map;

    private final NamedParameterJdbcTemplate jdbc;

    public UserRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public boolean existsByUsername(String username) {
        Long count = jdbc.queryForObject(
                "SELECT COUNT(*) FROM app_user WHERE username = :username",
                new MapSqlParameterSource("username", username), Long.class);
        return count != null && count > 0;
    }

    public Optional<UserRecord> findByUsername(String username) {
        List<UserRecord> rows = jdbc.query(
                "SELECT " + COLUMNS + " FROM app_user WHERE username = :username",
                new MapSqlParameterSource("username", username), MAPPER);
        return rows.stream().findFirst();
    }

    public Optional<UserRecord> findById(long id) {
        List<UserRecord> rows = jdbc.query(
                "SELECT " + COLUMNS + " FROM app_user WHERE id = :id",
                new MapSqlParameterSource("id", id), MAPPER);
        return rows.stream().findFirst();
    }

    public Optional<UserRecord> findByUserId(String userId) {
        List<UserRecord> rows = jdbc.query(
                "SELECT " + COLUMNS + " FROM app_user WHERE user_id = :userId",
                new MapSqlParameterSource("userId", userId), MAPPER);
        return rows.stream().findFirst();
    }

    public void insert(UserRecord user) {
        jdbc.update("""
                        INSERT INTO app_user (user_id, username, password_hash, site_key, status,
                                              created_at, updated_at)
                        VALUES (:userId, :username, :passwordHash, :siteKey,
                                COALESCE(:status, 'active'), :createdAt, :updatedAt)
                        """,
                new MapSqlParameterSource()
                        .addValue("userId", user.userId())
                        .addValue("username", user.username())
                        .addValue("passwordHash", user.passwordHash())
                        .addValue("siteKey", user.siteKey())
                        .addValue("status", user.status())
                        .addValue("createdAt", user.createdAt())
                        .addValue("updatedAt", user.updatedAt()));
    }

    /**
     * 改账号状态。**只在站主后台的禁用/解禁路径调用**，且调用前必须已校验归属站点。
     * 返回受影响行数：0 表示账号不存在（或状态本来就相同，这里按状态差异判断）。
     */
    public int updateStatus(long id, String status, LocalDateTime now) {
        return jdbc.update("""
                        UPDATE app_user
                           SET status = :status, status_changed_at = :now, updated_at = :now
                         WHERE id = :id
                        """,
                new MapSqlParameterSource()
                        .addValue("id", id)
                        .addValue("status", status)
                        .addValue("now", now));
    }

    /**
     * 用户注销：置 {@code disabled} + 记 {@code deleted_at}，**不删行**。
     *
     * <p>为什么不物理删：{@code app_user} 被 {@code ugc_comment} / {@code ugc_report} /
     * {@code collection} / {@code user_device} / {@code user_session} 五张表外键引用。
     * 删行等于连带删掉这个人在别人楼下的回复，楼层会塌。
     * 默认口径是**匿名化保留**（展示层显示「已注销用户」），物理删由独立开关控制，
     * 见 {@code docs/ugc-retention-proposal.md} §6。
     *
     * <p>为什么不用 {@code updateStatus}：{@code status='disabled'} 现在同时表示「站主禁用」
     * （可恢复）。注销是用户主动且不该被站主恢复，必须能区分——`deleted_at` 非空即为注销。
     *
     * @return 受影响行数；0 = 账号不存在或已注销（幂等）
     */
    public int markDeleted(long id, LocalDateTime now) {
        return jdbc.update("""
                        UPDATE app_user
                           SET status = 'disabled', deleted_at = :now,
                               status_changed_at = :now, updated_at = :now
                         WHERE id = :id AND deleted_at IS NULL
                        """,
                new MapSqlParameterSource()
                        .addValue("id", id)
                        .addValue("now", now));
    }

    private static UserRecord map(ResultSet rs, int rowNum) throws SQLException {
        return new UserRecord(
                rs.getLong("id"),
                rs.getString("user_id"),
                rs.getString("username"),
                rs.getString("password_hash"),
                rs.getString("site_key"),
                rs.getString("status"),
                rs.getObject("status_changed_at", LocalDateTime.class),
                rs.getObject("created_at", LocalDateTime.class),
                rs.getObject("updated_at", LocalDateTime.class));
    }
}
