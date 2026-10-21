package com.otaku.work;

import com.otaku.common.TagsJson;
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
 * work 表的读写。
 *
 * 排序固定 ORDER BY id ASC：契约只要求"稳定"，而分页要稳定就必须有个唯一键排序，
 * 用 updated_at 单独排会在同毫秒内抖动，导致翻页重复或漏记录。
 */
@Repository
public class WorkRepository {

    private static final String COLUMNS = """
            id, work_id, work_type, title, summary, release_year,
            cover_source_url, cover_cache_key, cover_cached_at,
            tags, rating_value, rating_scale, rating_source,
            source, source_id, source_url, created_at, updated_at
            """;

    private static final RowMapper<WorkRecord> MAPPER = WorkRepository::map;

    private final NamedParameterJdbcTemplate jdbc;

    public WorkRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public Optional<WorkRecord> findBySourceKey(String source, String sourceId) {
        List<WorkRecord> rows = jdbc.query(
                "SELECT " + COLUMNS + " FROM work WHERE source = :source AND source_id = :sourceId",
                new MapSqlParameterSource().addValue("source", source).addValue("sourceId", sourceId),
                MAPPER);
        return rows.stream().findFirst();
    }

    public Optional<WorkRecord> findByWorkId(String workId) {
        List<WorkRecord> rows = jdbc.query(
                "SELECT " + COLUMNS + " FROM work WHERE work_id = :workId",
                new MapSqlParameterSource("workId", workId),
                MAPPER);
        return rows.stream().findFirst();
    }

    public void insert(WorkRecord record) {
        String sql = """
                INSERT INTO work (work_id, work_type, title, summary, release_year,
                                  cover_source_url, cover_cache_key, cover_cached_at,
                                  tags, rating_value, rating_scale, rating_source,
                                  source, source_id, source_url, created_at, updated_at)
                VALUES (:workId, :workType, :title, :summary, :releaseYear,
                        :coverSourceUrl, :coverCacheKey, :coverCachedAt,
                        :tagsJson, :ratingValue, :ratingScale, :ratingSource,
                        :source, :sourceId, :sourceUrl, :createdAt, :updatedAt)
                """;
        jdbc.update(sql, baseParams(record)
                .addValue("createdAt", record.createdAt())
                .addValue("updatedAt", record.updatedAt()));
    }

    /** 只更新内容字段；work_id / source / source_id / created_at 永不变。 */
    public void updateContent(WorkRecord record) {
        String sql = """
                UPDATE work SET title = :title,
                                summary = :summary,
                                release_year = :releaseYear,
                                cover_source_url = :coverSourceUrl,
                                cover_cache_key = :coverCacheKey,
                                cover_cached_at = :coverCachedAt,
                                tags = :tagsJson,
                                rating_value = :ratingValue,
                                rating_scale = :ratingScale,
                                rating_source = :ratingSource,
                                source_url = :sourceUrl,
                                updated_at = :updatedAt
                WHERE id = :id
                """;
        jdbc.update(sql, baseParams(record)
                .addValue("id", record.id())
                .addValue("updatedAt", record.updatedAt()));
    }

    public void updateCoverCache(long id, String cacheKey, LocalDateTime cachedAt) {
        jdbc.update("UPDATE work SET cover_cache_key = :key, cover_cached_at = :at WHERE id = :id",
                new MapSqlParameterSource()
                        .addValue("key", cacheKey)
                        .addValue("at", cachedAt)
                        .addValue("id", id));
    }

    public List<WorkRecord> findPage(String workType, String titlePattern, int limit, int offset) {
        MapSqlParameterSource params = new MapSqlParameterSource()
                .addValue("limit", limit)
                .addValue("offset", offset);
        StringBuilder sql = new StringBuilder("SELECT " + COLUMNS + " FROM work");
        appendWhere(sql, params, workType, titlePattern);
        sql.append(" ORDER BY id ASC LIMIT :limit OFFSET :offset");
        return jdbc.query(sql.toString(), params, MAPPER);
    }

    public long count(String workType, String titlePattern) {
        MapSqlParameterSource params = new MapSqlParameterSource();
        StringBuilder sql = new StringBuilder("SELECT COUNT(*) FROM work");
        appendWhere(sql, params, workType, titlePattern);
        Long total = jdbc.queryForObject(sql.toString(), params, Long.class);
        return total == null ? 0L : total;
    }

    private static void appendWhere(StringBuilder sql, MapSqlParameterSource params,
                                    String workType, String titlePattern) {
        sql.append(" WHERE 1 = 1");
        if (workType != null) {
            sql.append(" AND work_type = :workType");
            params.addValue("workType", workType);
        }
        if (titlePattern != null) {
            sql.append(" AND title LIKE :titlePattern ESCAPE '!'");
            params.addValue("titlePattern", titlePattern);
        }
    }

    private static MapSqlParameterSource baseParams(WorkRecord record) {
        return new MapSqlParameterSource()
                .addValue("workId", record.workId())
                .addValue("workType", record.workType())
                .addValue("title", record.title())
                .addValue("summary", record.summary())
                .addValue("releaseYear", record.releaseYear())
                .addValue("coverSourceUrl", record.coverSourceUrl())
                .addValue("coverCacheKey", record.coverCacheKey())
                .addValue("coverCachedAt", record.coverCachedAt())
                .addValue("tagsJson", record.tagsJson())
                .addValue("ratingValue", record.ratingValue())
                .addValue("ratingScale", record.ratingScale())
                .addValue("ratingSource", record.ratingSource())
                .addValue("source", record.source())
                .addValue("sourceId", record.sourceId())
                .addValue("sourceUrl", record.sourceUrl());
    }

    private static WorkRecord map(ResultSet rs, int rowNum) throws SQLException {
        return new WorkRecord(
                rs.getLong("id"),
                rs.getString("work_id"),
                rs.getString("work_type"),
                rs.getString("title"),
                rs.getString("summary"),
                // 必须用 getObject：getInt 会把 NULL 读成 0，等于凭空造出一个"公元 0 年"。
                rs.getObject("release_year", Integer.class),
                rs.getString("cover_source_url"),
                rs.getString("cover_cache_key"),
                rs.getObject("cover_cached_at", LocalDateTime.class),
                TagsJson.canonical(rs.getString("tags")),
                rs.getBigDecimal("rating_value"),
                rs.getString("rating_scale"),
                rs.getString("rating_source"),
                rs.getString("source"),
                rs.getString("source_id"),
                rs.getString("source_url"),
                rs.getObject("created_at", LocalDateTime.class),
                rs.getObject("updated_at", LocalDateTime.class)
        );
    }
}
