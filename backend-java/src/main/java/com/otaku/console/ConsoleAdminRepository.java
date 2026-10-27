package com.otaku.console;

import com.otaku.console.dto.ConsoleDtos;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Optional;

/**
 * 站主名单读写（二期：站主自助增删）。
 *
 * <p>与 {@link SiteAdminRepository} 的分工：那个是**鉴权链**用的（按用户名/主键查，
 * 联表带站点状态）；这个只服务后台的名单管理，**每条 SQL 都带 site_key**，
 * 站主拿不到别的站点的行。
 *
 * <p>为什么停用是改状态而不是删行：删了就没法审计、也没法恢复；
 * 而且 `site_admin_session` 里还有历史会话引用着这一行。
 */
@Repository
public class ConsoleAdminRepository {

    private final NamedParameterJdbcTemplate jdbc;

    public ConsoleAdminRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public List<ConsoleDtos.AdminItem> list(String siteKey) {
        return jdbc.query("""
                        SELECT admin_id, username, display_name, status, created_at, last_login_at
                          FROM site_admin
                         WHERE site_key = :siteKey
                         ORDER BY id ASC
                        """,
                new MapSqlParameterSource("siteKey", siteKey),
                (rs, rowNum) -> new ConsoleDtos.AdminItem(
                        rs.getString("admin_id"),
                        rs.getString("username"),
                        rs.getString("display_name"),
                        rs.getString("status"),
                        toOffset(rs.getObject("created_at", LocalDateTime.class)),
                        toOffset(rs.getObject("last_login_at", LocalDateTime.class)),
                        false));
    }

    /** 带站点条件的单条查询：返回空 = 不存在**或**不属于本站，调用方统一按 404/403 处理。 */
    public Optional<SiteAdminRow> find(String adminId, String siteKey) {
        return jdbc.query("""
                        SELECT id, admin_id, site_key, username, password_hash, display_name,
                               identity_source, status, last_login_at
                          FROM site_admin
                         WHERE admin_id = :adminId AND site_key = :siteKey
                        """,
                new MapSqlParameterSource().addValue("adminId", adminId).addValue("siteKey", siteKey),
                (rs, rowNum) -> new SiteAdminRow(
                        rs.getLong("id"),
                        rs.getString("admin_id"),
                        rs.getString("site_key"),
                        null,
                        SiteRecord.STATUS_ACTIVE,
                        rs.getString("username"),
                        rs.getString("password_hash"),
                        rs.getString("display_name"),
                        rs.getString("identity_source"),
                        rs.getString("status"),
                        rs.getObject("last_login_at", LocalDateTime.class)))
                .stream().findFirst();
    }

    /** 不看站点，只为把「不存在」（404）与「属于别站」（403）分开。 */
    public Optional<String> siteKeyOf(String adminId) {
        return jdbc.queryForList("SELECT site_key FROM site_admin WHERE admin_id = :adminId",
                        new MapSqlParameterSource("adminId", adminId), String.class)
                .stream().findFirst();
    }

    private static java.time.OffsetDateTime toOffset(LocalDateTime value) {
        return value == null ? null : value.atOffset(ZoneOffset.UTC);
    }
}
