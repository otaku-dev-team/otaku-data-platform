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
     * 列表分页。{@code category} 为 {@code null} 时**不加分类条件**（不过滤）。
     *
     * <p>这里必须动态拼而不是写 {@code category <=> :category}：
     * MySQL 的 NULL 安全相等在右值为 NULL 时等价于 {@code IS NULL}，
     * 于是「不过滤」会变成「只查没有分类的那批」——列表一打开就少了大半，
     * 而返回 200 + 少量条目看不出是错的。
     *
     * <p>另一条同样要注意：别写 {@code IS NOT DISTINCT FROM}，那是 PostgreSQL 语法，
     * MySQL 直接报 1064（本机实测踩过）。
     */
    public List<ArticleRecord> findPage(String category, int limit, int offset) {
        StringBuilder sql = new StringBuilder("SELECT ").append(COLUMNS).append(" FROM article");
        MapSqlParameterSource params = new MapSqlParameterSource()
                .addValue("limit", limit)
                .addValue("offset", offset);
        if (category != null) {
            sql.append(" WHERE category = :category");
            params.addValue("category", category);
        }
        sql.append(" ORDER BY published_at DESC, id DESC LIMIT :limit OFFSET :offset");
        return jdbc.query(sql.toString(), params, MAPPER);
    }

    public long count(String category) {
        StringBuilder sql = new StringBuilder("SELECT COUNT(*) FROM article");
        MapSqlParameterSource params = new MapSqlParameterSource();
        if (category != null) {
            sql.append(" WHERE category = :category");
            params.addValue("category", category);
        }
        Long total = jdbc.queryForObject(sql.toString(), params, Long.class);
        return total == null ? 0L : total;
    }

    /**
     * 反查：关联作品里含这个 subject id 的资讯条数（#409 作品→资讯）。
     *
     * <p>语义前提见 {@link ArticleRelatedIdsSemantics}：只有在
     * {@code related_work_ids} 已切到 bangumi subject id 时，拿 {@code work.source_id}
     * 来匹配才成立。切流前调用方不该走到这里。
     */
    public long countRelatedToWork(String sourceId) {
        Long total = jdbc.queryForObject(
                "SELECT COUNT(*) FROM article WHERE " + relatedToWorkPredicate(sourceId),
                new MapSqlParameterSource("sourceId", sourceId),
                Long.class);
        return total == null ? 0L : total;
    }

    /**
     * 反查一页资讯，按发布时间倒序。
     *
     * <p>排序键与列表接口一致（{@code published_at DESC, id DESC}）：同一分钟发布的多条
     * 若无次级键，翻页会重复或漏条。
     *
     * <p>没有为 {@code related_work_ids} 建索引：它是 JSON 数组，MySQL 的多值索引要
     * {@code CAST(... AS UNSIGNED ARRAY)}，而这一列混着两套纯数字号、长度也不定，
     * 建了反而把「语义没切」的状态固化进索引。当前 article 只有千级行，全表扫一次
     * 是毫秒级；等资讯上万再按 {@code (article_id, subject_id)} 引一张反查表。
     */
    public List<ArticleRecord> findRelatedToWork(String sourceId, int limit, int offset) {
        return jdbc.query(
                "SELECT " + COLUMNS + " FROM article WHERE " + relatedToWorkPredicate(sourceId)
                        + " ORDER BY published_at DESC, id DESC LIMIT :limit OFFSET :offset",
                new MapSqlParameterSource()
                        .addValue("sourceId", sourceId)
                        .addValue("limit", limit)
                        .addValue("offset", offset),
                MAPPER);
    }

    /**
     * 匹配条件：{@code related_work_ids} 含该 id。
     *
     * <p>两种存法都算命中——导入请求把它声明成 {@code List<String>}，落库是字符串数组
     * （{@code ["11972"]}）；而数据侧 publisher 是从 SQLite 读出来的整数
     * （{@code bangumi_id}），如果哪天不经 Java 归一直接写库就是数字数组
     * （{@code [11972]}）。{@code JSON_CONTAINS} 对类型敏感，字符串 {@code "11972"}
     * 与数字 {@code 11972} **不相等**，只写一种就会有一半数据静默查不到。
     *
     * <p>数字分支只在 {@code sourceId} 全是数字时拼——{@code CAST('abc' AS JSON)}
     * 在 MySQL 里直接报错 3141，不能无脑加。
     */
    static String relatedToWorkPredicate(String sourceId) {
        String predicate = "JSON_CONTAINS(related_work_ids, JSON_QUOTE(:sourceId))";
        if (sourceId != null && !sourceId.isEmpty() && sourceId.chars().allMatch(Character::isDigit)) {
            predicate = "(" + predicate + " OR JSON_CONTAINS(related_work_ids, CAST(:sourceId AS JSON)))";
        }
        return predicate;
    }

    /** 库里出现过的全部分类，条数多的在前。给客户端的分类筛选用。 */
    /**
     * 资讯↔资讯候选（#414）：**同标签重叠**或**同分类**。
     *
     * <p>召回故意宽一点（多取 `limit` 倍），精细排序交给 Service——共享标签数
     * 要在 Java 里算（MySQL 8 没有数组交集函数，只有 `JSON_OVERLAPS` 判断「有没有重叠」）。
     * 在 SQL 里排只能按时间，会把「只共享一个标签的新资讯」排在「共享三个标签的旧资讯」前面。
     *
     * <p>`tagsJson` 为 null 时只按分类召回；两个条件都为空时调用方不该调用本方法。
     */
    public List<ArticleRecord> findRelatedCandidates(String excludeArticleId, String tagsJson,
                                                     String category, int limit) {
        java.util.List<String> conditions = new java.util.ArrayList<>();
        MapSqlParameterSource params = new MapSqlParameterSource()
                .addValue("exclude", excludeArticleId)
                .addValue("limit", limit);
        if (tagsJson != null) {
            // JSON_OVERLAPS 要求两边都是数组；CAST(... AS JSON) 把参数转成 JSON 值，
            // 直接传字符串会被当成 JSON 字符串（"[\"a\"]"）而永远不重叠。
            conditions.add("(tags IS NOT NULL AND JSON_OVERLAPS(tags, CAST(:tagsJson AS JSON)))");
            params.addValue("tagsJson", tagsJson);
        }
        if (category != null) {
            conditions.add("category = :category");
            params.addValue("category", category);
        }
        String sql = "SELECT " + COLUMNS + " FROM article WHERE article_id <> :exclude"
                + " AND (" + String.join(" OR ", conditions) + ")"
                + " ORDER BY published_at DESC, id DESC LIMIT :limit";
        return jdbc.query(sql, params, MAPPER);
    }

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