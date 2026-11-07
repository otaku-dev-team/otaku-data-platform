package com.otaku.profile;

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
 * 账号资料与头像 key 的读写（#378）。
 *
 * <p>所有方法带 {@code id}（内部主键）而不是对外 user_id：调用方只从会话拿，
 * 不接受客户端传入——与收藏 / 浏览同一套隔离原则。
 */
@Repository
public class AccountProfileRepository {

    private static final String COLUMNS =
            "id, user_id, username, display_name, bio, avatar_key, created_at";

    private static final RowMapper<AccountProfileRecord> MAPPER = AccountProfileRepository::map;

    private final NamedParameterJdbcTemplate jdbc;

    public AccountProfileRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public Optional<AccountProfileRecord> find(long id) {
        List<AccountProfileRecord> rows = jdbc.query(
                "SELECT " + COLUMNS + " FROM app_user"
                        + " WHERE id = :id AND deleted_at IS NULL",
                new MapSqlParameterSource("id", id), MAPPER);
        return rows.stream().findFirst();
    }

    public void updateProfile(long id, String displayName, String bio, LocalDateTime now) {
        jdbc.update("""
                        UPDATE app_user
                           SET display_name = :displayName, bio = :bio, updated_at = :now
                         WHERE id = :id AND deleted_at IS NULL
                        """,
                new MapSqlParameterSource()
                        .addValue("id", id)
                        .addValue("displayName", displayName)
                        .addValue("bio", bio)
                        .addValue("now", now));
    }

    public Optional<String> findAvatarKey(long id) {
        List<String> keys = jdbc.query(
                "SELECT avatar_key FROM app_user WHERE id = :id",
                new MapSqlParameterSource("id", id),
                (rs, rowNum) -> rs.getString("avatar_key"));
        // 列可为 null：不能用 Optional.of(keys.get(0))，否则「没头像」直接 NPE。
        return keys.isEmpty() ? Optional.empty() : Optional.ofNullable(keys.get(0));
    }

    public void updateAvatarKey(long id, String avatarKey, LocalDateTime now) {
        jdbc.update("""
                        UPDATE app_user SET avatar_key = :avatarKey, updated_at = :now
                         WHERE id = :id
                        """,
                new MapSqlParameterSource()
                        .addValue("id", id)
                        .addValue("avatarKey", avatarKey)
                        .addValue("now", now));
    }

    private static AccountProfileRecord map(ResultSet rs, int rowNum) throws SQLException {
        return new AccountProfileRecord(
                rs.getLong("id"),
                rs.getString("user_id"),
                rs.getString("username"),
                rs.getString("display_name"),
                rs.getString("bio"),
                rs.getString("avatar_key"),
                rs.getObject("created_at", LocalDateTime.class));
    }
}
