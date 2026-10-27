package com.otaku.console;

import com.otaku.common.LikePattern;
import com.otaku.console.dto.ConsoleDtos;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;
import org.springframework.util.StringUtils;

import java.time.LocalDateTime;
import java.util.List;

/**
 * 站主后台的用户查询。**每条 SQL 都带 {@code u.site_key = :siteKey}**。
 *
 * <p>这条 where 不是"记得加"，而是这类后台唯一真正重要的地方：
 * 少了它，A 站能看到并禁用 B 站的用户，而接口看起来一切正常（200、有数据）。
 * 集成测试 {@code ConsoleIsolationIntegrationTest} 就是为它写的。
 *
 * <p>{@code site_key IS NULL} 的历史账号不出现在任何站点的列表里——
 * 它们不属于任何人，交给平台侧处理，而不是"第一个看到的人就能管"。
 */
@Repository
public class ConsoleUserRepository {

    private final NamedParameterJdbcTemplate jdbc;

    public ConsoleUserRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public List<ConsoleDtos.UserItem> page(String siteKey, String status, String keyword,
                                           int limit, int offset, LocalDateTime now) {
        MapSqlParameterSource params = new MapSqlParameterSource()
                .addValue("siteKey", siteKey)
                .addValue("now", now)
                .addValue("limit", limit)
                .addValue("offset", offset);
        String where = where(status, keyword, params);

        return jdbc.query("""
                        SELECT u.user_id, u.username, u.status, u.created_at, u.status_changed_at,
                               (SELECT COUNT(*) FROM user_session s
                                 WHERE s.user_id = u.id
                                   AND s.revoked_at IS NULL
                                   AND s.expires_at > :now) AS active_sessions
                          FROM app_user u
                        """ + where + """
                         ORDER BY u.id ASC
                         LIMIT :limit OFFSET :offset
                        """,
                params,
                (rs, rowNum) -> new ConsoleDtos.UserItem(
                        rs.getString("user_id"),
                        rs.getString("username"),
                        rs.getString("status"),
                        toOffset(rs.getObject("created_at", LocalDateTime.class)),
                        toOffset(rs.getObject("status_changed_at", LocalDateTime.class)),
                        rs.getLong("active_sessions")));
    }

    public long count(String siteKey, String status, String keyword) {
        MapSqlParameterSource params = new MapSqlParameterSource("siteKey", siteKey);
        String where = where(status, keyword, params);
        Long count = jdbc.queryForObject("SELECT COUNT(*) FROM app_user u" + where, params, Long.class);
        return count == null ? 0 : count;
    }

    private static String where(String status, String keyword, MapSqlParameterSource params) {
        StringBuilder sql = new StringBuilder(" WHERE u.site_key = :siteKey");
        if (StringUtils.hasText(status)) {
            sql.append(" AND u.status = :status");
            params.addValue("status", status);
        }
        if (StringUtils.hasText(keyword)) {
            // 与作品搜索同一套转义：用户输入的 % 和 _ 是普通字符，不是通配符
            sql.append(" AND u.username LIKE :q ESCAPE '!'");
            params.addValue("q", LikePattern.contains(keyword.trim()));
        }
        return sql.toString();
    }

    private static java.time.OffsetDateTime toOffset(LocalDateTime value) {
        return value == null ? null : value.atOffset(java.time.ZoneOffset.UTC);
    }
}
