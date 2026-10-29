package com.otaku.ugc;

import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.support.GeneratedKeyHolder;
import org.springframework.jdbc.support.KeyHolder;
import org.springframework.stereotype.Repository;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;

/**
 * ugc_comment 的读写。
 *
 * <p>所有查询都带 {@code site_key}：它是隔离的唯一依据，且**只从登录态取**
 * （{@code app_user.site_key}），不接受请求参数。少写一个 site_key，A 站的评论就会
 * 出现在 B 站作品页上——这条是红线，测试里有对应用例。
 */
@Repository
public class UgcRepository {

    /** 内部行：多带 username 与状态，供列表渲染与删除鉴权用。 */
    public record Row(
            long id,
            String siteKey,
            String workId,
            long userId,
            String username,
            String body,
            String status,
            LocalDateTime createdAt
    ) {
    }

    private static final RowMapper<Row> MAPPER = (rs, rowNum) -> new Row(
            rs.getLong("id"),
            rs.getString("site_key"),
            rs.getString("work_id"),
            rs.getLong("user_id"),
            rs.getString("username"),
            rs.getString("body"),
            rs.getString("status"),
            rs.getObject("created_at", LocalDateTime.class));

    private final NamedParameterJdbcTemplate jdbc;

    public UgcRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public long insert(String siteKey, String workId, long userId, String body, LocalDateTime now) {
        KeyHolder keyHolder = new GeneratedKeyHolder();
        jdbc.update("""
                INSERT INTO ugc_comment (site_key, work_id, user_id, body, status, created_at, updated_at)
                VALUES (:siteKey, :workId, :userId, :body, 'published', :now, :now)
                """, new MapSqlParameterSource()
                .addValue("siteKey", siteKey)
                .addValue("workId", workId)
                .addValue("userId", userId)
                .addValue("body", body)
                .addValue("now", now), keyHolder, new String[]{"id"});
        Number key = keyHolder.getKey();
        if (key == null) {
            throw new IllegalStateException("插入评论后拿不到自增主键");
        }
        return key.longValue();
    }

    /** 作品页列表：只要 published，最新在前。 */
    public List<Row> findPublished(String siteKey, String workId, int limit, int offset) {
        return jdbc.query("""
                        SELECT c.id, c.site_key, c.work_id, c.user_id, u.username, c.body, c.status, c.created_at
                          FROM ugc_comment c
                          JOIN app_user u ON u.id = c.user_id
                         WHERE c.site_key = :siteKey AND c.work_id = :workId AND c.status = 'published'
                         ORDER BY c.created_at DESC, c.id DESC
                         LIMIT :limit OFFSET :offset
                        """, new MapSqlParameterSource()
                        .addValue("siteKey", siteKey)
                        .addValue("workId", workId)
                        .addValue("limit", limit)
                        .addValue("offset", offset), MAPPER);
    }

    public long countPublished(String siteKey, String workId) {
        Long total = jdbc.queryForObject("""
                SELECT COUNT(*) FROM ugc_comment
                 WHERE site_key = :siteKey AND work_id = :workId AND status = 'published'
                """, new MapSqlParameterSource()
                .addValue("siteKey", siteKey)
                .addValue("workId", workId), Long.class);
        return total == null ? 0L : total;
    }

    /** 按 id 取一行（删除鉴权用）：同样带 site_key，跨站 id 直接当不存在。 */
    public Optional<Row> findById(String siteKey, long id) {
        List<Row> rows = jdbc.query("""
                SELECT c.id, c.site_key, c.work_id, c.user_id, u.username, c.body, c.status, c.created_at
                  FROM ugc_comment c
                  JOIN app_user u ON u.id = c.user_id
                 WHERE c.site_key = :siteKey AND c.id = :id
                """, new MapSqlParameterSource()
                .addValue("siteKey", siteKey)
                .addValue("id", id), MAPPER);
        return rows.stream().findFirst();
    }

    /**
     * 作者删除自己的评论：软删（status='deleted'），保留行以便追溯。
     * 只对 published / hidden 生效，重复删除不改变任何东西（幂等）。
     */
    public int markDeleted(String siteKey, long id, LocalDateTime now) {
        return jdbc.update("""
                UPDATE ugc_comment SET status = 'deleted', updated_at = :now
                 WHERE site_key = :siteKey AND id = :id AND status <> 'deleted'
                """, new MapSqlParameterSource()
                .addValue("siteKey", siteKey)
                .addValue("id", id)
                .addValue("now", now));
    }

    /** 最近一段时间内该用户发了几条（防刷屏）。 */
    public int countRecentByUser(String siteKey, long userId, LocalDateTime since) {
        Integer count = jdbc.queryForObject("""
                SELECT COUNT(*) FROM ugc_comment
                 WHERE site_key = :siteKey AND user_id = :userId AND created_at >= :since
                   AND status <> 'deleted'
                """, new MapSqlParameterSource()
                .addValue("siteKey", siteKey)
                .addValue("userId", userId)
                .addValue("since", since), Integer.class);
        return count == null ? 0 : count;
    }
}
