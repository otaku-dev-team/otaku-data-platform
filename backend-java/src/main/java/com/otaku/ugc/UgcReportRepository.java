package com.otaku.ugc;

import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;

/**
 * 评论举报工单（#240 B2b）。
 *
 * <p>一个用户对一条评论只产生一张工单（{@code uk_report_comment_reporter}）：
 * 举报按钮被连点、或同一人反复举报，都不该在后台堆出一排重复项。
 * 重复提交走 {@link #findByCommentAndReporter} 返回原工单，而不是报错。
 */
@Repository
public class UgcReportRepository {

    public record ReportRow(
            long id,
            String siteKey,
            long commentId,
            String workId,
            String workTitle,
            String author,
            String body,
            String reason,
            String status,
            LocalDateTime createdAt
    ) {
    }

    private static final RowMapper<ReportRow> MAPPER = (rs, rowNum) -> new ReportRow(
            rs.getLong("id"),
            rs.getString("site_key"),
            rs.getLong("comment_id"),
            rs.getString("work_id"),
            rs.getString("work_title"),
            rs.getString("username"),
            rs.getString("body"),
            rs.getString("reason"),
            rs.getString("status"),
            rs.getObject("created_at", LocalDateTime.class));

    private static final String SELECT = """
            SELECT r.id, r.site_key, r.comment_id, c.work_id,
                   COALESCE(w.title, c.work_id) AS work_title,
                   u.username, c.body, r.reason, r.status, r.created_at
              FROM ugc_report r
              JOIN ugc_comment c ON c.id = r.comment_id
              JOIN app_user u ON u.id = c.user_id
              LEFT JOIN work w ON w.work_id = c.work_id
            """;

    private final NamedParameterJdbcTemplate jdbc;

    public UgcReportRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /** 返回影响行数：0 = 这个人对这条评论已经举报过（唯一键挡住）。 */
    public int insert(String siteKey, long commentId, long reporterId, String reason, LocalDateTime now) {
        return jdbc.update("""
                INSERT IGNORE INTO ugc_report
                    (site_key, comment_id, reporter_id, reason, status, created_at)
                VALUES (:siteKey, :commentId, :reporterId, :reason, 'open', :now)
                """, new MapSqlParameterSource()
                .addValue("siteKey", siteKey)
                .addValue("commentId", commentId)
                .addValue("reporterId", reporterId)
                .addValue("reason", reason)
                .addValue("now", now));
    }

    public Optional<ReportRow> findByCommentAndReporter(String siteKey, long commentId, long reporterId) {
        return jdbc.query(SELECT + " WHERE r.site_key = :siteKey AND r.comment_id = :commentId"
                        + " AND r.reporter_id = :reporterId",
                new MapSqlParameterSource()
                        .addValue("siteKey", siteKey)
                        .addValue("commentId", commentId)
                        .addValue("reporterId", reporterId), MAPPER)
                .stream().findFirst();
    }

    public Optional<ReportRow> findById(String siteKey, long id) {
        return jdbc.query(SELECT + " WHERE r.site_key = :siteKey AND r.id = :id",
                new MapSqlParameterSource().addValue("siteKey", siteKey).addValue("id", id), MAPPER)
                .stream().findFirst();
    }

    /** 后台队列：按站点过滤，可按状态筛（null = 全部），最新在前。 */
    public List<ReportRow> listForConsole(String siteKey, String status, int limit, int offset) {
        StringBuilder sql = new StringBuilder(SELECT).append(" WHERE r.site_key = :siteKey");
        MapSqlParameterSource params = new MapSqlParameterSource()
                .addValue("siteKey", siteKey)
                .addValue("limit", limit)
                .addValue("offset", offset);
        if (status != null) {
            sql.append(" AND r.status = :status");
            params.addValue("status", status);
        }
        sql.append(" ORDER BY r.created_at DESC, r.id DESC LIMIT :limit OFFSET :offset");
        return jdbc.query(sql.toString(), params, MAPPER);
    }

    public long countForConsole(String siteKey, String status) {
        StringBuilder sql = new StringBuilder("SELECT COUNT(*) FROM ugc_report WHERE site_key = :siteKey");
        MapSqlParameterSource params = new MapSqlParameterSource().addValue("siteKey", siteKey);
        if (status != null) {
            sql.append(" AND status = :status");
            params.addValue("status", status);
        }
        Long total = jdbc.queryForObject(sql.toString(), params, Long.class);
        return total == null ? 0L : total;
    }

    /** 处置结果只对 open 生效：已处理过的再点一次不改变处理人与时间（幂等）。 */
    public int markHandled(String siteKey, long id, String status, String adminId, LocalDateTime now) {
        return jdbc.update("""
                UPDATE ugc_report SET status = :status, handled_at = :now, handled_by = :adminId
                 WHERE site_key = :siteKey AND id = :id AND status = 'open'
                """, new MapSqlParameterSource()
                .addValue("siteKey", siteKey)
                .addValue("id", id)
                .addValue("status", status)
                .addValue("adminId", adminId)
                .addValue("now", now));
    }
}
