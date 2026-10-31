package com.otaku.ugc;

import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.support.GeneratedKeyHolder;
import org.springframework.jdbc.support.KeyHolder;
import org.springframework.stereotype.Repository;

import java.time.LocalDateTime;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/**
 * ugc_review 的读写（#240 B2c⑥）。
 *
 * <p>与 {@link UgcRepository} 同一套边界：所有查询带 {@code site_key}，作者名对已注销用户匿名化，
 * 公开列表只认 {@code published}。
 *
 * <p>一人一条由唯一键 {@code uk_review_user_work} 兜底，业务层不用先查后插（并发下也安全）。
 */
@Repository
public class UgcReviewRepository {

    /** 内部行：带 username 与状态，供列表渲染与鉴权。 */
    public record Row(
            long id,
            String siteKey,
            String workId,
            long userId,
            String username,
            Integer rating,
            String body,
            String status,
            LocalDateTime createdAt,
            LocalDateTime editedAt
    ) {
    }

    /**
     * 导出用的一行：比 {@link Row} 多作品标题、少 userId。
     *
     * <p>为什么单独一个 record：导出是**给站主的凭据**，作品标题必须带上（他没有我们的
     * work_id 索引，光看 `W-xxx` 认不出是哪部片子）；userId 是内部主键，不该出现在交还文件里。
     */
    public record ExportRow(
            long id,
            String siteKey,
            String workId,
            String workTitle,
            String username,
            Integer rating,
            String body,
            String status,
            LocalDateTime createdAt,
            LocalDateTime editedAt
    ) {
    }

    private static final RowMapper<Row> MAPPER = (rs, rowNum) -> new Row(
            rs.getLong("id"),
            rs.getString("site_key"),
            rs.getString("work_id"),
            rs.getLong("user_id"),
            rs.getString("username"),
            (Integer) rs.getObject("rating", Integer.class),
            rs.getString("body"),
            rs.getString("status"),
            rs.getObject("created_at", LocalDateTime.class),
            rs.getObject("edited_at", LocalDateTime.class));

    private static final RowMapper<ExportRow> EXPORT_MAPPER = (rs, rowNum) -> new ExportRow(
            rs.getLong("id"),
            rs.getString("site_key"),
            rs.getString("work_id"),
            rs.getString("work_title"),
            rs.getString("username"),
            (Integer) rs.getObject("rating", Integer.class),
            rs.getString("body"),
            rs.getString("status"),
            rs.getObject("created_at", LocalDateTime.class),
            rs.getObject("edited_at", LocalDateTime.class));

    private final NamedParameterJdbcTemplate jdbc;

    public UgcReviewRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public long insert(String siteKey, String workId, long userId, Integer rating, String body,
                       String status, LocalDateTime now) {
        KeyHolder keyHolder = new GeneratedKeyHolder();
        jdbc.update("""
                INSERT INTO ugc_review (site_key, work_id, user_id, rating, body, status,
                                        created_at, updated_at)
                VALUES (:siteKey, :workId, :userId, :rating, :body, :status, :now, :now)
                """, new MapSqlParameterSource()
                .addValue("siteKey", siteKey)
                .addValue("workId", workId)
                .addValue("userId", userId)
                .addValue("rating", rating)
                .addValue("body", body)
                .addValue("status", status)
                .addValue("now", now), keyHolder, new String[]{"id"});
        Number key = keyHolder.getKey();
        if (key == null) {
            throw new IllegalStateException("插入点评后拿不到自增主键");
        }
        return key.longValue();
    }

    /** 作品页列表：只要 published，最新在前。 */
    public List<Row> findPublished(String siteKey, String workId, int limit, int offset) {
        return jdbc.query("""
                        SELECT r.id, r.site_key, r.work_id, r.user_id,
                               CASE WHEN u.deleted_at IS NULL THEN u.username
                                    ELSE '已注销用户' END AS username,
                               r.rating, r.body, r.status, r.created_at, r.edited_at
                          FROM ugc_review r
                          JOIN app_user u ON u.id = r.user_id
                         WHERE r.site_key = :siteKey AND r.work_id = :workId
                           AND r.status = 'published'
                         ORDER BY r.created_at DESC, r.id DESC
                         LIMIT :limit OFFSET :offset
                        """, new MapSqlParameterSource()
                        .addValue("siteKey", siteKey)
                        .addValue("workId", workId)
                        .addValue("limit", limit)
                        .addValue("offset", offset), MAPPER);
    }

    /** 已发布的点评条数（含只写文字不打分的）。 */
    public long countPublished(String siteKey, String workId) {
        Long total = jdbc.queryForObject("""
                SELECT COUNT(*) FROM ugc_review
                 WHERE site_key = :siteKey AND work_id = :workId AND status = 'published'
                """, new MapSqlParameterSource()
                .addValue("siteKey", siteKey)
                .addValue("workId", workId), Long.class);
        return total == null ? 0L : total;
    }

    /**
     * 导出（数据交还）：按站点过滤，可按状态筛（null = 全部，含已删），最新在前。
     *
     * <p>与 {@link #findPublished} 的区别是**不限制 work_id、也不限制 published**——
     * 交还要的是这个站的全部点评，包括被隐藏和被作者删掉的。
     */
    public List<ExportRow> findForExport(String siteKey, String status, int limit) {
        StringBuilder sql = new StringBuilder("""
                SELECT r.id, r.site_key, r.work_id, COALESCE(w.title, r.work_id) AS work_title,
                       CASE WHEN u.deleted_at IS NULL THEN u.username
                            ELSE '已注销用户' END AS username,
                       r.rating, r.body, r.status, r.created_at, r.edited_at
                  FROM ugc_review r
                  JOIN app_user u ON u.id = r.user_id
                  LEFT JOIN work w ON w.work_id = r.work_id
                 WHERE r.site_key = :siteKey
                """);
        MapSqlParameterSource params = new MapSqlParameterSource()
                .addValue("siteKey", siteKey)
                .addValue("limit", limit);
        if (status != null) {
            sql.append(" AND r.status = :status");
            params.addValue("status", status);
        }
        sql.append(" ORDER BY r.created_at DESC, r.id DESC LIMIT :limit");
        return jdbc.query(sql.toString(), params, EXPORT_MAPPER);
    }

    /** 导出的总条数（用来判断有没有被上限截断）。 */
    public long countForExport(String siteKey, String status) {
        StringBuilder sql = new StringBuilder(
                "SELECT COUNT(*) FROM ugc_review r WHERE r.site_key = :siteKey");
        MapSqlParameterSource params = new MapSqlParameterSource().addValue("siteKey", siteKey);
        if (status != null) {
            sql.append(" AND r.status = :status");
            params.addValue("status", status);
        }
        Long total = jdbc.queryForObject(sql.toString(), params, Long.class);
        return total == null ? 0L : total;
    }

    /**
     * 评分聚合：均分只算**打了分**的（只写文字的点评不参与均分，否则会被当成 0 分拉低）。
     *
     * @return [0]=总条数（published）、[1]=已打分条数、[2]=均分（可为 null）
     */
    public Object[] ratingStats(String siteKey, String workId) {
        return jdbc.query("""
                SELECT COUNT(*) AS total,
                       SUM(rating IS NOT NULL) AS rated,
                       AVG(rating) AS average
                  FROM ugc_review
                 WHERE site_key = :siteKey AND work_id = :workId AND status = 'published'
                """, new MapSqlParameterSource()
                .addValue("siteKey", siteKey)
                .addValue("workId", workId),
                rs -> {
                    if (!rs.next()) {
                        return new Object[]{0L, 0L, null};
                    }
                    long total = rs.getLong("total");
                    long rated = rs.getLong("rated");
                    Double average = (Double) rs.getObject("average", Double.class);
                    return new Object[]{total, rated, average};
                });
    }

    /** 各分数的条数（1–10），没有的分数不出现。 */
    public Map<Integer, Integer> ratingDistribution(String siteKey, String workId) {
        Map<Integer, Integer> dist = new LinkedHashMap<>();
        jdbc.query("""
                        SELECT rating, COUNT(*) AS c
                          FROM ugc_review
                         WHERE site_key = :siteKey AND work_id = :workId
                           AND status = 'published' AND rating IS NOT NULL
                         GROUP BY rating ORDER BY rating
                        """, new MapSqlParameterSource()
                        .addValue("siteKey", siteKey)
                        .addValue("workId", workId),
                rs -> {
                    dist.put(rs.getInt("rating"), rs.getInt("c"));
                });
        return dist;
    }

    public Optional<Row> findById(String siteKey, long id) {
        return jdbc.query("""
                        SELECT r.id, r.site_key, r.work_id, r.user_id,
                               CASE WHEN u.deleted_at IS NULL THEN u.username
                                    ELSE '已注销用户' END AS username,
                               r.rating, r.body, r.status, r.created_at, r.edited_at
                          FROM ugc_review r
                          JOIN app_user u ON u.id = r.user_id
                         WHERE r.site_key = :siteKey AND r.id = :id
                        """, new MapSqlParameterSource()
                        .addValue("siteKey", siteKey)
                        .addValue("id", id), MAPPER).stream().findFirst();
    }

    public boolean existsByUserAndWork(long userId, String workId) {
        Long count = jdbc.queryForObject("""
                SELECT COUNT(*) FROM ugc_review WHERE user_id = :userId AND work_id = :workId
                """, new MapSqlParameterSource()
                .addValue("userId", userId)
                .addValue("workId", workId), Long.class);
        return count != null && count > 0;
    }

    /** 改内容：只对 published / pending 生效（hidden 是站主处置过的、deleted 已撤回）。 */
    public int update(String siteKey, long id, Integer rating, String body, String status,
                      LocalDateTime now) {
        return jdbc.update("""
                UPDATE ugc_review
                   SET rating = :rating, body = :body, status = :status,
                       edited_at = :now, updated_at = :now
                 WHERE site_key = :siteKey AND id = :id AND status IN ('published', 'pending')
                """, new MapSqlParameterSource()
                .addValue("siteKey", siteKey)
                .addValue("id", id)
                .addValue("rating", rating)
                .addValue("body", body)
                .addValue("status", status)
                .addValue("now", now));
    }

    /** 软删（幂等）：保留行便于追溯，物理清理由留存作业统一做。 */
    public int markDeleted(String siteKey, long id, LocalDateTime now) {
        return jdbc.update("""
                UPDATE ugc_review SET status = 'deleted', updated_at = :now
                 WHERE site_key = :siteKey AND id = :id AND status <> 'deleted'
                """, new MapSqlParameterSource()
                .addValue("siteKey", siteKey)
                .addValue("id", id)
                .addValue("now", now));
    }
}
