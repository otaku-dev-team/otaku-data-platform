package com.otaku.collection;

import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

import java.math.BigDecimal;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;

/**
 * 收藏读写。
 *
 * 所有方法都强制带 user_id 条件——这是验收 E7（不能读写他人个人数据）的实现落点：
 * user_id 只从会话取，任何接口都不接受客户端传入的 user_id。
 */
@Repository
public class CollectionRepository {

    private static final String COLUMNS = "id, user_id, work_id, status, created_at, updated_at";

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

    /** 只改状态；updated_at 同步推进（服务端最后成功提交生效）。 */
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

    public List<CollectionWorkRow> findPage(long userPk, int limit, int offset) {
        return jdbc.query("""
                        SELECT c.work_id, c.status, c.updated_at,
                               w.work_type, w.title, w.cover_source_url, w.tags,
                               w.rating_value, w.rating_scale, w.rating_source
                          FROM collection c
                          JOIN work w ON w.work_id = c.work_id
                         WHERE c.user_id = :userId
                         ORDER BY c.updated_at DESC, c.id DESC
                         LIMIT :limit OFFSET :offset
                        """,
                new MapSqlParameterSource()
                        .addValue("userId", userPk)
                        .addValue("limit", limit)
                        .addValue("offset", offset),
                CollectionRepository::mapRow);
    }

    public long count(long userPk) {
        Long total = jdbc.queryForObject(
                "SELECT COUNT(*) FROM collection WHERE user_id = :userId",
                new MapSqlParameterSource("userId", userPk), Long.class);
        return total == null ? 0 : total;
    }

    /** 单条联表查询，用于写操作后立即返回最新视图。 */
    public Optional<CollectionWorkRow> findRow(long userPk, String workId) {
        List<CollectionWorkRow> rows = jdbc.query("""
                        SELECT c.work_id, c.status, c.updated_at,
                               w.work_type, w.title, w.cover_source_url, w.tags,
                               w.rating_value, w.rating_scale, w.rating_source
                          FROM collection c
                          JOIN work w ON w.work_id = c.work_id
                         WHERE c.user_id = :userId AND c.work_id = :workId
                        """,
                new MapSqlParameterSource().addValue("userId", userPk).addValue("workId", workId),
                CollectionRepository::mapRow);
        return rows.stream().findFirst();
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
        BigDecimal rating = rs.getBigDecimal("rating_value");
        return new CollectionWorkRow(
                rs.getString("work_id"),
                rs.getString("status"),
                rs.getObject("updated_at", LocalDateTime.class),
                rs.getString("work_type"),
                rs.getString("title"),
                rs.getString("cover_source_url"),
                rs.getString("tags"),
                rating,
                rs.getString("rating_scale"),
                rs.getString("rating_source"));
    }
}
