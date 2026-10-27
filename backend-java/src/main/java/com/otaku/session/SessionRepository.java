package com.otaku.session;

import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;

/**
 * 会话读写。
 *
 * 关键行为（验收 C1/C6/C9/C10）：
 * - 一次登录插一行，多台设备互不影响；
 * - 退出登录只把当前这一行置 revoked_at，其他设备仍然有效；
 * - 校验时要求 revoked_at IS NULL 且 expires_at 未过期。
 */
@Repository
public class SessionRepository {

    private static final RowMapper<SessionRecord> MAPPER = (rs, rowNum) -> new SessionRecord(
            rs.getLong("id"),
            rs.getLong("user_id"),
            rs.getObject("last_seen_at", LocalDateTime.class));

    private final NamedParameterJdbcTemplate jdbc;

    public SessionRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public void create(long userPk, String tokenHash, String deviceLabel,
                       LocalDateTime now, LocalDateTime expiresAt) {
        jdbc.update("""
                        INSERT INTO user_session (token_hash, user_id, device_label,
                                                  created_at, last_seen_at, expires_at)
                        VALUES (:tokenHash, :userId, :deviceLabel, :now, :now, :expiresAt)
                        """,
                new MapSqlParameterSource()
                        .addValue("tokenHash", tokenHash)
                        .addValue("userId", userPk)
                        .addValue("deviceLabel", deviceLabel)
                        .addValue("now", now)
                        .addValue("expiresAt", expiresAt));
    }

    public Optional<SessionRecord> findActive(String tokenHash, LocalDateTime now) {
        List<SessionRecord> rows = jdbc.query("""
                        SELECT id, user_id, last_seen_at
                          FROM user_session
                         WHERE token_hash = :tokenHash
                           AND revoked_at IS NULL
                           AND expires_at > :now
                        """,
                new MapSqlParameterSource()
                        .addValue("tokenHash", tokenHash)
                        .addValue("now", now),
                MAPPER);
        return rows.stream().findFirst();
    }

    public void touch(long sessionId, LocalDateTime now) {
        jdbc.update("UPDATE user_session SET last_seen_at = :now WHERE id = :id",
                new MapSqlParameterSource().addValue("now", now).addValue("id", sessionId));
    }

    /** 只撤销这一个令牌对应的会话；返回受影响行数。 */
    public int revoke(String tokenHash, LocalDateTime now) {
        return jdbc.update("""
                        UPDATE user_session SET revoked_at = :now
                         WHERE token_hash = :tokenHash AND revoked_at IS NULL
                        """,
                new MapSqlParameterSource()
                        .addValue("now", now)
                        .addValue("tokenHash", tokenHash));
    }

    /**
     * 撤销某个用户的**全部**会话；返回受影响行数。
     *
     * <p>只有一个调用点：站主后台禁用用户（Issue #144）。禁用必须当场生效——
     * 只改 {@code app_user.status} 而不撤会话的话，已经登录的设备还能继续用 30 天，
     * 站主会以为"禁用没生效"。
     */
    public int revokeAllForUser(long userPk, LocalDateTime now) {
        return jdbc.update("""
                        UPDATE user_session SET revoked_at = :now
                         WHERE user_id = :userId AND revoked_at IS NULL
                        """,
                new MapSqlParameterSource()
                        .addValue("userId", userPk)
                        .addValue("now", now));
    }

    /**
     * 清理已过期或已撤销超过保留期的会话行。
     * 判定用"过期/撤销时间 < 截止点"，避免把刚过期但还在排查中的记录立刻删掉。
     */
    public int purgeStale(LocalDateTime cutoff) {
        return jdbc.update("""
                        DELETE FROM user_session
                         WHERE (expires_at < :cutoff)
                            OR (revoked_at IS NOT NULL AND revoked_at < :cutoff)
                        """,
                new MapSqlParameterSource("cutoff", cutoff));
    }

    public int countActive(long userPk, LocalDateTime now) {
        Integer count = jdbc.queryForObject("""
                        SELECT COUNT(*) FROM user_session
                         WHERE user_id = :userId AND revoked_at IS NULL AND expires_at > :now
                        """,
                new MapSqlParameterSource().addValue("userId", userPk).addValue("now", now),
                Integer.class);
        return count == null ? 0 : count;
    }
}
