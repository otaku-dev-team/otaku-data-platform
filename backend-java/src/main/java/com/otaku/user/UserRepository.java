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
            "id, user_id, username, password_hash, created_at, updated_at";

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

    public void insert(UserRecord user) {
        jdbc.update("""
                        INSERT INTO app_user (user_id, username, password_hash, created_at, updated_at)
                        VALUES (:userId, :username, :passwordHash, :createdAt, :updatedAt)
                        """,
                new MapSqlParameterSource()
                        .addValue("userId", user.userId())
                        .addValue("username", user.username())
                        .addValue("passwordHash", user.passwordHash())
                        .addValue("createdAt", user.createdAt())
                        .addValue("updatedAt", user.updatedAt()));
    }

    private static UserRecord map(ResultSet rs, int rowNum) throws SQLException {
        return new UserRecord(
                rs.getLong("id"),
                rs.getString("user_id"),
                rs.getString("username"),
                rs.getString("password_hash"),
                rs.getObject("created_at", LocalDateTime.class),
                rs.getObject("updated_at", LocalDateTime.class));
    }
}
