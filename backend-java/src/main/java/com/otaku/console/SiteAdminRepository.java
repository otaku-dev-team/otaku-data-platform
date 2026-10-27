package com.otaku.console;

import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;

/**
 * 站主名单（提案 §4.1：站主用网站账号登录后，还要校验是否在名单内）。
 *
 * <p>过渡态（{@code identity_source=platform}）由平台建号、我们用 BCrypt 存摘要；
 * 网站 OAuth 就绪后新增 {@code identity_source=site_oauth} 的行，{@code password_hash} 留空，
 * 登录改走站点授权。表结构现在就支持两种，切的时候不用改鉴权链。
 */
@Repository
public class SiteAdminRepository {

    private static final String COLUMNS = """
            a.id, a.admin_id, a.site_key, a.username, a.password_hash, a.display_name,
            a.identity_source, a.status, a.last_login_at,
            s.display_name AS site_name, s.status AS site_status
            """;

    private static final RowMapper<SiteAdminRow> MAPPER = (rs, rowNum) -> new SiteAdminRow(
            rs.getLong("id"),
            rs.getString("admin_id"),
            rs.getString("site_key"),
            rs.getString("site_name"),
            rs.getString("site_status"),
            rs.getString("username"),
            rs.getString("password_hash"),
            rs.getString("display_name"),
            rs.getString("identity_source"),
            rs.getString("status"),
            rs.getObject("last_login_at", LocalDateTime.class));

    private final NamedParameterJdbcTemplate jdbc;

    public SiteAdminRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public Optional<SiteAdminRow> findByUsername(String username) {
        List<SiteAdminRow> rows = jdbc.query("""
                        SELECT %s
                          FROM site_admin a JOIN site s ON s.site_key = a.site_key
                         WHERE a.username = :username
                        """.formatted(COLUMNS),
                new MapSqlParameterSource("username", username), MAPPER);
        return rows.stream().findFirst();
    }

    public Optional<SiteAdminRow> findByAdminId(String adminId) {
        List<SiteAdminRow> rows = jdbc.query("""
                        SELECT %s
                          FROM site_admin a JOIN site s ON s.site_key = a.site_key
                         WHERE a.admin_id = :adminId
                        """.formatted(COLUMNS),
                new MapSqlParameterSource("adminId", adminId), MAPPER);
        return rows.stream().findFirst();
    }

    /** 鉴权用：一次查回站主 + 站点状态。找不到返回空（调用方按 401 处理）。 */
    public Optional<SiteAdminRow> findSessionOwner(long adminPk) {
        List<SiteAdminRow> rows = jdbc.query("""
                        SELECT %s
                          FROM site_admin a JOIN site s ON s.site_key = a.site_key
                         WHERE a.id = :adminPk
                        """.formatted(COLUMNS),
                new MapSqlParameterSource("adminPk", adminPk), MAPPER);
        return rows.stream().findFirst();
    }

    public boolean existsByUsername(String username) {
        Long count = jdbc.queryForObject("SELECT COUNT(*) FROM site_admin WHERE username = :username",
                new MapSqlParameterSource("username", username), Long.class);
        return count != null && count > 0;
    }

    public void insert(String adminId, String siteKey, String username, String passwordHash,
                       String displayName, String identitySource, String externalUserId,
                       LocalDateTime now) {
        jdbc.update("""
                        INSERT INTO site_admin (admin_id, site_key, username, password_hash, display_name,
                                                identity_source, external_user_id, status,
                                                created_at, updated_at)
                        VALUES (:adminId, :siteKey, :username, :passwordHash, :displayName,
                                :identitySource, :externalUserId, 'active', :now, :now)
                        """,
                new MapSqlParameterSource()
                        .addValue("adminId", adminId)
                        .addValue("siteKey", siteKey)
                        .addValue("username", username)
                        .addValue("passwordHash", passwordHash)
                        .addValue("displayName", displayName)
                        .addValue("identitySource", identitySource)
                        .addValue("externalUserId", externalUserId)
                        .addValue("now", now));
    }

    public void touchLogin(long adminPk, LocalDateTime now) {
        jdbc.update("UPDATE site_admin SET last_login_at = :now, updated_at = :now WHERE id = :id",
                new MapSqlParameterSource().addValue("id", adminPk).addValue("now", now));
    }

    /** 站主状态流转只发生在 /internal/**（平台侧），后台不能动站主名单。 */
    public void updateStatus(String adminId, String status, LocalDateTime now) {
        jdbc.update("""
                        UPDATE site_admin SET status = :status, updated_at = :now
                         WHERE admin_id = :adminId
                        """,
                new MapSqlParameterSource()
                        .addValue("adminId", adminId)
                        .addValue("status", status)
                        .addValue("now", now));
    }
}
