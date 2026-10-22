package com.otaku.article;

import com.fasterxml.jackson.databind.ObjectMapper;
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
 * article 表的读写。
 *
 * <p>排序统一 {@code published_at DESC, id DESC}：资讯天然是新的在前，
 * {@code id} 作次级键 —— 同一分钟发布的多条若无次级键，顺序由存储引擎决定，
 * 翻页时会看到重复或漏条。
 *
 * <p>JSON 列读出时统一过紧凑序列化归一，保证「是否变化」可比较（理由见
 * {@link ArticleRecord}）。
 */
@Repository
public class ArticleRepository {

    private static final String COLUMNS = """
            id, article_id, source, source_id, title, summary, body, category,
            published_at, source_name, source_url, cover_url,
            tags, related_work_ids, created_at, updated_at
            """;

    private static final RowMapper<ArticleRecord> MAPPER = ArticleRepository::map;

    private static final ObjectMapper JSON = new ObjectMapper();

    /**
     * 读库时把 JSON 列归一成紧凑形式。
     *
     * <p>MySQL 会把 JSON 重新格式化后读出（{@code ["a","b"]} 变 {@code ["a", "b"]}），
     * 若「是否变化」用字符串比较，每次重跑都会判成 changed → 变成 updated，
     * 「重跑应全部 unchanged」的验收就挂了。
     */
    static String canonicalJson(String json) {
        if (json == null || json.isBlank()) {
            return null;
        }
        try {
            return JSON.readTree(json).toString();
        } catch (Exception ex) {
            // 解析不了按未提供处理：这两列是附加信息，不该让整条资讯读不出来。
            return null;
        }
    }

    private final NamedParameterJdbcTemplate jdbc;

    public ArticleRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public Optional<ArticleRecord> findBySourceKey(String source, String sourceId) {
        List<ArticleRecord> rows = jdbc.query(
                "SELECT " + COLUMNS + " FROM article WHERE source = :source AND source_id = :sourceId",
                new MapSqlParameterSource().addValue("source", source).addValue("sourceId", sourceId),
                MAPPER);
        return rows.stream().findFirst();
    }

    public Optional<ArticleRecord> findByArticleId(String articleId) {
        List<ArticleRecord> rows = jdbc.query(
                "SELECT " + COLUMNS + " FROM article WHERE article_id = :articleId",
                new MapSqlParameterSource("articleId", articleId),
                MAPPER);
        return rows.stream().findFirst();
    }

    /**
     * 列表分页。{@code category} 为 {@code null} 时不过滤。
     *
     * <p>用 {@code IS NOT DISTINCT FROM} 而不是 {@code =}：后者遇到 NULL 参数永远不匹配，
     * 会把「全部」查成空列表，而空列表在这里是合法数据，错了也看不出来。
     */
    public List<ArticleRecord> findPage(String category, int limit, int offset) {
        String sql = "SELECT " + COLUMNS + " FROM article"
                + " WHERE category IS NOT DISTINCT FROM :category"
                + " ORDER BY published_at DESC, id DESC"
                + " LIMIT :limit OFFSET :offset";
        return jdbc.query(sql,
                new MapSqlParameterSource()
                        .addValue("category", category)
                        .addValue("limit", limit)
                        .addValue("offset", offset),
                MAPPER);
    }

    public long count(String category) {
        Long total = jdbc.queryForObject(
                "SELECT COUNT(*) FROM article WHERE category IS NOT DISTINCT FROM :category",
                new MapSqlParameterSource("category", category),
                Long.class);
        return total == null ? 0L : total;
    }

    /** 库里出现过的全部分类，条数多的在前。给客户端的分类筛选用。 */
    public List<String> findCategories() {
        return jdbc.queryForList(
                "SELECT category FROM article WHERE category IS NOT NULL"
                        + " GROUP BY category ORDER BY COUNT(*) DESC, category ASC",
                new MapSqlParameterSource(),
                String.class);
    }

    public void insert(ArticleRecord record) {
        String sql = """
                INSERT INTO article (article_id, source, source_id, title, summary, body, category,
                                     published_at, source_name, source_url, cover_url,
                                     tags, related_work_ids, created_at, updated_at)
                VALUES (:articleId, :source, :sourceId, :title, :summary, :body, :category,
                        :publishedAt, :sourceName, :sourceUrl, :coverUrl,
                        :tagsJson, :relatedWorkIdsJson, :createdAt, :updatedAt)
                """;
        jdbc.update(sql, params(record)
                .addValue("createdAt", record.createdAt())
                .addValue("updatedAt", record.updatedAt()));
    }

    public void update(ArticleRecord record) {
        String sql = """
                UPDATE article
                   SET summary           = :summary,
                       body              = :body,
                       category          = :category,
                       published_at      = :publishedAt,
                       source_name       = :sourceName,
                       source_url        = :sourceUrl,
                       cover_url         = :coverUrl,
                       tags              = :tagsJson,
                       related_work_ids  = :relatedWorkIdsJson,
                       updated_at        = :updatedAt
                 WHERE id = :id
                """;
        jdbc.update(sql, params(record)
                .addValue("id", record.id())
                .addValue("updatedAt", record.updatedAt()));
    }

    private MapSqlParameterSource params(ArticleRecord record) {
        return new MapSqlParameterSource()
                .addValue("articleId", record.articleId())
                .addValue("source", record.source())
                .addValue("sourceId", record.sourceId())
                .addValue("title", record.title())
                .addValue("summary", record.summary())
                .addValue("body", record.body())
                .addValue("category", record.category())
                .addValue("publishedAt", record.publishedAt())
                .addValue("sourceName", record.sourceName())
                .addValue("sourceUrl", record.sourceUrl())
                .addValue("coverUrl", record.coverUrl())
                .addValue("tagsJson", record.tagsJson())
                .addValue("relatedWorkIdsJson", record.relatedWorkIdsJson());
    }

    private static ArticleRecord map(ResultSet rs, int rowNum) throws SQLException {
        return new ArticleRecord(
                rs.getLong("id"),
                rs.getString("article_id"),
                rs.getString("source"),
                rs.getString("source_id"),
                rs.getString("title"),
                rs.getString("summary"),
                rs.getString("body"),
                rs.getString("category"),
                // getObject：getTimestamp 会把 NULL 变成 null，但走时区转换的
                // 读法在部分驱动上会给出「本地时区的假零点」，这里统一用 getObject。
                rs.getObject("published_at", LocalDateTime.class),
                rs.getString("source_name"),
                rs.getString("source_url"),
                rs.getString("cover_url"),
                canonicalJson(rs.getString("tags")),
                canonicalJson(rs.getString("related_work_ids")),
                rs.getObject("created_at", LocalDateTime.class),
                rs.getObject("updated_at", LocalDateTime.class));
    }
}