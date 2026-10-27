package com.otaku.console;

import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

import java.time.LocalDateTime;

/**
 * 后台会话。与客户端 `user_session` 是两张表，理由：
 *
 * <ul>
 *   <li>两套凭据互不通用——站主令牌偷去调客户端接口不行，客户端令牌也进不了后台；</li>
 *   <li>有效期不同：客户端 30 天（用户不想天天登录），后台 12 小时（管理权限，越短越好）；</li>
 *   <li>禁用站主只需改 {@code site_admin.status}，不必连客户端会话一起处理。</li>
 * </ul>
 */
@Repository
public class SiteAdminSessionRepository {

    private final NamedParameterJdbcTemplate jdbc;

    public SiteAdminSessionRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public void create(long adminPk, String tokenHash, String deviceLabel,
                       LocalDateTime now, LocalDateTime expiresAt) {
        jdbc.update("""
                        INSERT INTO site_admin_session (token_hash, site_admin_id, device_label,
                                                        created_at, last_seen_at, expires_at)
                        VALUES (:tokenHash, :adminPk, :deviceLabel, :now, :now, :expiresAt)
                        """,
                new MapSqlParameterSource()
                        .addValue("tokenHash", tokenHash)
                        .addValue("adminPk", adminPk)
                        .addValue("deviceLabel", deviceLabel)
                        .addValue("now", now)
                        .addValue("expiresAt", expiresAt));
    }

    /** 有效会话的站主主键；无效/过期/已撤销一律返回空。 */
    public java.util.Optional<Long> findActiveAdminPk(String tokenHash, LocalDateTime now) {
        return jdbc.query("""
                        SELECT site_admin_id
                          FROM site_admin_session
                         WHERE token_hash = :tokenHash
                           AND revoked_at IS NULL
                           AND expires_at > :now
                        """,
                new MapSqlParameterSource().addValue("tokenHash", tokenHash).addValue("now", now),
                (rs, rowNum) -> rs.getLong("site_admin_id")).stream().findFirst();
    }

    public void touch(String tokenHash, LocalDateTime now) {
        jdbc.update("""
                        UPDATE site_admin_session SET last_seen_at = :now
                         WHERE token_hash = :tokenHash AND revoked_at IS NULL
                        """,
                new MapSqlParameterSource().addValue("tokenHash", tokenHash).addValue("now", now));
    }

    public int revoke(String tokenHash, LocalDateTime now) {
        return jdbc.update("""
                        UPDATE site_admin_session SET revoked_at = :now
                         WHERE token_hash = :tokenHash AND revoked_at IS NULL
                        """,
                new MapSqlParameterSource().addValue("tokenHash", tokenHash).addValue("now", now));
    }

    public int purgeStale(LocalDateTime cutoff) {
        return jdbc.update("""
                        DELETE FROM site_admin_session
                         WHERE expires_at < :cutoff
                            OR (revoked_at IS NOT NULL AND revoked_at < :cutoff)
                        """,
                new MapSqlParameterSource("cutoff", cutoff));
    }
}
