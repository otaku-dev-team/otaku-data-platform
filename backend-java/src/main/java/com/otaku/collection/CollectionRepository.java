package com.otaku.collection;

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
 * 收藏读写。
 *
 * 所有方法都强制带 user_id 条件——这是验收 C5（看不到他人收藏）的实现落点：
 * user_id 只从会话取，任何接口都不接受客户端传入。
 */
@Repository
public class CollectionRepository {

    /** 契约 §4.4 允许按状态过滤，"none" 表示"已收藏但未设状态"。 */
    static final String STATUS_NONE = "none";

    private static final String COLUMNS = "id, user_id, work_id, status, created_at, updated_at";

    private static final String JOIN_COLUMNS = """
            c.work_id, c.status, c.created_at, c.updated_at,
            w.work_type, w.title, w.cover_source_url
            """;

    private static final RowMapper<CollectionRecord> MAPPER = CollectionRepository::map;

    private final NamedParameterJdbcTemplate jdbc;

    public CollectionRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public Optional<CollectionRecord> find(long userPk, String workId) {
        List<CollectionRecord> rows = jdbc.query(
                "SELECT " + COLUMNS + " FROM collection WHERE user_id = :userId AND work_id = :workId",
                new MapSqlParameterSource().addValue("userId", userPk).addValue("workId", workId),
                MAPPER);
        return rows.stream().findFirst();
    }

    public void insert(long userPk, String workId, String status, LocalDateTime now) {
        jdbc.update("""
                        INSERT INTO collection (user_id, work_id, status, created_at, updated_at)
                        VALUES (:userId, :workId, :status, :now, :now)
                        """,
                new MapSqlParameterSource()
                        .addValue("userId", userPk)
                        .addValue("workId", workId)
                        .addValue("status", status)
                        .addValue("now", now));
    }

    /** 只改状态；updated_at 同步推进（服务端最后成功提交生效，即 LWW）。 */
    public void updateStatus(long userPk, String workId, String status, LocalDateTime now) {
        jdbc.update("""
                        UPDATE collection SET status = :status, updated_at = :now
                         WHERE user_id = :userId AND work_id = :workId
                        """,
                new MapSqlParameterSource()
                        .addValue("status", status)
                        .addValue("now", now)
                        .addValue("userId", userPk)
                        .addValue("workId", workId));
    }

    public int delete(long userPk, String workId) {
        return jdbc.update("DELETE FROM collection WHERE user_id = :userId AND work_id = :workId",
                new MapSqlParameterSource().addValue("userId", userPk).addValue("workId", workId));
    }

    /**
     * 分页查询。排序 fixed 为 contracted 的 updated_at DESC, work_id ASC ——
     * 第二个键保证同一秒写入的多条记录在翻页时不会跳条。
     */
    public List<CollectionWorkRow> findPage(long userPk, String statusFilter, int limit, int offset) {
        MapSqlParameterSource params = new MapSqlParameterSource()
                .addValue("userId", userPk)
                .addValue("limit", limit)
                .addValue("offset", offset);
        String sql = "SELECT " + JOIN_COLUMNS
                + "  FROM collection c JOIN work w ON w.work_id = c.work_id"
                + " WHERE c.user_id = :userId"
                + statusCondition(statusFilter, params)
                + " ORDER BY c.updated_at DESC, c.work_id ASC LIMIT :limit OFFSET :offset";
        return jdbc.query(sql, params, CollectionRepository::mapRow);
    }

    public long count(long userPk, String statusFilter) {
        MapSqlParameterSource params = new MapSqlParameterSource("userId", userPk);
        String sql = "SELECT COUNT(*) FROM collection c WHERE c.user_id = :userId"
                + statusCondition(statusFilter, params);
        Long total = jdbc.queryForObject(sql, params, Long.class);
        return total == null ? 0 : total;
    }

    /** 单条联表查询；写操作后立即返回最新状态，以及 GET 单条时用。 */
    public Optional<CollectionWorkRow> findRow(long userPk, String workId) {
        List<CollectionWorkRow> rows = jdbc.query(
                "SELECT " + JOIN_COLUMNS
                        + "  FROM collection c JOIN work w ON w.work_id = c.work_id"
                        + " WHERE c.user_id = :userId AND c.work_id = :workId",
                new MapSqlParameterSource().addValue("userId", userPk).addValue("workId", workId),
                CollectionRepository::mapRow);
        return rows.stream().findFirst();
    }

    private static String statusCondition(String statusFilter, MapSqlParameterSource params) {
        if (statusFilter == null) {
            return "";
        }
        if (STATUS_NONE.equals(statusFilter)) {
            return " AND c.status IS NULL";
        }
        params.addValue("status", statusFilter);
        return " AND c.status = :status";
    }

    private static CollectionRecord map(ResultSet rs, int rowNum) throws SQLException {
        return new CollectionRecord(
                rs.getLong("id"),
                rs.getLong("user_id"),
                rs.getString("work_id"),
                rs.getString("status"),
                rs.getObject("created_at", LocalDateTime.class),
                rs.getObject("updated_at", LocalDateTime.class));
    }

    private static CollectionWorkRow mapRow(ResultSet rs, int rowNum) throws SQLException {
        return new CollectionWorkRow(
                rs.getString("work_id"),
                rs.getString("status"),
                rs.getObject("created_at", LocalDateTime.class),
                rs.getObject("updated_at", LocalDateTime.class),
                rs.getString("work_type"),
                rs.getString("title"),
                rs.getString("cover_source_url"));
    }
}
