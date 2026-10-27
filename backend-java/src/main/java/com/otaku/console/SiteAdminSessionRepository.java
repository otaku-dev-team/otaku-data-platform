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

    /** 停用单个站主时撤他的全部会话：改 status 只挡住"下一次登录"，已登录的设备要当场掉线。 */
    public int revokeAllForAdmin(long adminPk, LocalDateTime now) {
        return jdbc.update("""
                        UPDATE site_admin_session SET revoked_at = :now
                         WHERE site_admin_id = :adminPk AND revoked_at IS NULL
                        """,
                new MapSqlParameterSource().addValue("adminPk", adminPk).addValue("now", now));
    }

    /** 改口令后撤销其它设备：当前这台继续可用，其他设备必须用新口令重登。 */
    public int revokeOthers(long adminPk, String keepTokenHash, LocalDateTime now) {
        return jdbc.update("""
                        UPDATE site_admin_session SET revoked_at = :now
                         WHERE site_admin_id = :adminPk
                           AND token_hash <> :keep
                           AND revoked_at IS NULL
                        """,
                new MapSqlParameterSource()
                        .addValue("adminPk", adminPk)
                        .addValue("keep", keepTokenHash)
                        .addValue("now", now));
    }

    /** 停用整个站点时撤该站全部站主的会话——与"每个请求都联表判断站点状态"双保险。 */
    public int revokeAllForSite(String siteKey, LocalDateTime now) {
        return jdbc.update("""
                        UPDATE site_admin_session ses
                          JOIN site_admin adm ON adm.id = ses.site_admin_id
                           SET ses.revoked_at = :now
                         WHERE adm.site_key = :siteKey AND ses.revoked_at IS NULL
                        """,
                new MapSqlParameterSource().addValue("siteKey", siteKey).addValue("now", now));
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
