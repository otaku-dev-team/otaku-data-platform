package com.otaku.work;

import com.otaku.common.TagsJson;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.support.GeneratedKeyHolder;
import org.springframework.jdbc.support.KeyHolder;
import org.springframework.stereotype.Repository;

import java.math.BigDecimal;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;

/**
 * work 表的读写。
 *
 * 排序默认 ORDER BY id ASC：契约只要求"稳定"，而分页要稳定就必须有个唯一键排序，
 * 用 updated_at 单独排会在同毫秒内抖动，导致翻页重复或漏记录。
 * 可选排序见 {@link WorkSort}，同样以 id 作次级键。
 *
 * <p>写入时会顺带维护 {@code work_tag}（见 {@link #replaceTags}）：它是标签筛选的反查表，
 * 与 work 行在同一个事务里更新，所以两者不会出现不一致的中间态。
 */
@Repository
public class WorkRepository {

    private static final String COLUMNS = """
            id, work_id, work_type, title, summary, release_year,
            cover_source_url, cover_cache_key, cover_cached_at,
            tags, rating_value, rating_scale, rating_source,
            source, source_id, source_url, created_at, updated_at
            """;

    /** 同一份列表加表别名，供两段式查询的外层用；从 COLUMNS 生成，不会与它走样。 */
    private static final String ALIASED_COLUMNS = java.util.Arrays.stream(COLUMNS.split(","))
            .map(String::trim)
            .filter(column -> !column.isEmpty())
            .map(column -> "w." + column)
            .collect(java.util.stream.Collectors.joining(", "));

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
        // 需要自增主键回填 work_tag.work_ref，所以走 KeyHolder 而不是普通 update。
        KeyHolder keyHolder = new GeneratedKeyHolder();
        jdbc.update(sql, baseParams(record)
                .addValue("createdAt", record.createdAt())
                .addValue("updatedAt", record.updatedAt()), keyHolder, new String[]{"id"});
        Number key = keyHolder.getKey();
        if (key == null) {
            throw new IllegalStateException("插入 work 后拿不到自增主键：" + record.workId());
        }
        replaceTags(key.longValue(), record.tagsJson(), record.workType(),
                record.ratingValue(), record.releaseYear());
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
        // 评分/年份/标签都可能变，而 work_tag 的索引里冗余了前两者，必须整组重写。
        replaceTags(record.id(), record.tagsJson(), record.workType(),
                record.ratingValue(), record.releaseYear());
    }

    /**
     * 用一组标签整体替换某作品的 work_tag 行（先删后插）。
     *
     * <p>为什么整组替换而不是增量：标签是「最多 5 个」的小集合，增量比对省不了多少，
     * 却要多一次读；而且 {@code tags = NULL} 时不覆盖的语义已经在
     * {@link com.otaku.importer.WorkMerger} 里处理完了，这里拿到的就是最终结果。
     *
     * <p>解析放在 SQL 里（{@code JSON_TABLE}），与回填脚本同一条路径，避免两处解析规则不一致。
     * {@code tagsJson} 一定来自 {@code TagsJson.write()}，是合法 JSON；若真损坏，
     * 这里抛错会让该条导入变 rejected——比默默丢掉标签更容易被发现。
     */
    private void replaceTags(long workRef, String tagsJson, String workType,
                             BigDecimal ratingValue, Integer releaseYear) {
        MapSqlParameterSource params = new MapSqlParameterSource("workRef", workRef);
        jdbc.update("DELETE FROM work_tag WHERE work_ref = :workRef", params);
        if (tagsJson == null) {
            return;
        }
        String sql = """
                INSERT IGNORE INTO work_tag (work_ref, tag, work_type, rating_value, release_year)
                SELECT :workRef, LEFT(jt.tag, 64), :workType, :ratingValue, :releaseYear
                FROM JSON_TABLE(CAST(:tagsJson AS JSON), '$[*]' COLUMNS (tag VARCHAR(255) PATH '$')) jt
                WHERE jt.tag IS NOT NULL AND jt.tag <> ''
                """;
        jdbc.update(sql, params
                .addValue("tagsJson", tagsJson)
                .addValue("workType", workType)
                .addValue("ratingValue", ratingValue)
                .addValue("releaseYear", releaseYear));
    }

    public void updateCoverCache(long id, String cacheKey, LocalDateTime cachedAt) {
        jdbc.update("UPDATE work SET cover_cache_key = :key, cover_cached_at = :at WHERE id = :id",
                new MapSqlParameterSource()
                        .addValue("key", cacheKey)
                        .addValue("at", cachedAt)
                        .addValue("id", id));
    }

    /**
     * 取一页。**两段式查询**：先在覆盖索引上数出这一页的 id，再回表取这 50 行。
     *
     * <p>为什么不直接 {@code SELECT 全列 ... LIMIT n OFFSET m}：OFFSET 越大，MySQL 要把
     * 前面 m 行**逐行回表**读出来再丢掉。55.6 万条实测，第 5000 页（OFFSET 249,950）：
     * 直接写 1218ms → 两段式 92ms。
     * 默认排序（主键顺序）无收益也不倒退，成本在顺序跳页本身（约 250ms）。
     *
     * <p>外层再排一次序是为了抵消 JOIN 可能打乱的顺序；只有 50 行，代价可忽略。
     * 真正的根治是键集分页（记住上一页末位 id），那需要改契约，另议。
     *
     * <p>带 {@code tag} 时内层换成查 {@code work_tag}：那两张索引里冗余了评分与年份，
     * 所以「标签 + 评分/年份排序」仍是有序扫描，不需要 filesort（35ms vs 772ms）。
     * 代价是标签内跳深页仍受 OFFSET 影响，与主表一致。
     */
    public List<WorkRecord> findPage(String workType, String titlePattern, String tag, WorkSort sort,
                                     int limit, int offset) {
        MapSqlParameterSource params = new MapSqlParameterSource()
                .addValue("limit", limit)
                .addValue("offset", offset);
        WorkSort effective = sort == null ? WorkSort.ID : sort;

        StringBuilder inner;
        if (tag == null) {
            inner = new StringBuilder("SELECT w.id AS id FROM work w WHERE 1 = 1");
            appendConditions(inner, params, workType, titlePattern);
            inner.append(" ORDER BY ").append(effective.orderBy("w"));
        } else {
            // 走关联表：标签条件的成本与标签基数成正比，而不是与全表成正比。
            params.addValue("tag", tag);
            // 只有标题关键词必须回表（title 不在 work_tag 里）；类型已经冗余进索引。
            // 为取 id 而回表是纯浪费：55.6 万条实测，`COUNT(*) ... JOIN work` 296ms
            // （46,000 次随机回表），纯索引扫描只要个位数毫秒。
            if (titlePattern != null) {
                inner = new StringBuilder("SELECT t.work_ref AS id FROM work_tag t"
                        + " JOIN work w ON w.id = t.work_ref WHERE t.tag = :tag");
                appendConditions(inner, params, workType, titlePattern);
            } else {
                inner = new StringBuilder("SELECT t.work_ref AS id FROM work_tag t WHERE t.tag = :tag");
                if (workType != null) {
                    inner.append(" AND t.work_type = :workType");
                    params.addValue("workType", workType);
                }
            }
            inner.append(" ORDER BY ").append(effective.orderByOnTagTable("t"));
        }
        inner.append(" LIMIT :limit OFFSET :offset");

        String sql = "SELECT " + ALIASED_COLUMNS + " FROM work w"
                + " JOIN (" + inner + ") p ON p.id = w.id"
                + " ORDER BY " + effective.orderBy("w");
        return jdbc.query(sql, params, MAPPER);
    }

    /**
     * 同标签作品（详情页「相关内容推荐」）。
     *
     * <p>用 {@code JSON_OVERLAPS} 求交集，配合 {@code idx_work_rating} 反向扫描：
     * 只要前 N 条，命中密集时扫几十行就够，55.6 万条实测 3ms。
     * 若改成「按共享标签数排序」则需要全表算分 + filesort（实测 1.0s），
     * 所以这里只按评分排——推荐理由由调用方用 basis_tags 呈现。
     */
    public List<WorkRecord> findRelated(long excludeId, String tagsJson, int limit) {
        String sql = "SELECT " + COLUMNS + " FROM work"
                + " WHERE id <> :excludeId"
                + " AND tags IS NOT NULL"
                + " AND JSON_OVERLAPS(tags, CAST(:tagsJson AS JSON))"
                + " ORDER BY rating_value DESC, id DESC"
                + " LIMIT :limit";
        return jdbc.query(sql, new MapSqlParameterSource()
                .addValue("excludeId", excludeId)
                .addValue("tagsJson", tagsJson)
                .addValue("limit", limit), MAPPER);
    }

    public long count(String workType, String titlePattern, String tag) {
        MapSqlParameterSource params = new MapSqlParameterSource();
        StringBuilder sql;
        if (tag == null) {
            sql = new StringBuilder("SELECT COUNT(*) FROM work w WHERE 1 = 1");
            appendConditions(sql, params, workType, titlePattern);
        } else {
            params.addValue("tag", tag);
            // 同 findPage：标题必须回表；类型已冗余进 work_tag，不必 JOIN。
            if (titlePattern != null) {
                sql = new StringBuilder("SELECT COUNT(*) FROM work_tag t"
                        + " JOIN work w ON w.id = t.work_ref WHERE t.tag = :tag");
                appendConditions(sql, params, workType, titlePattern);
            } else {
                sql = new StringBuilder("SELECT COUNT(*) FROM work_tag t WHERE t.tag = :tag");
                if (workType != null) {
                    sql.append(" AND t.work_type = :workType");
                    params.addValue("workType", workType);
                }
            }
        }
        Long total = jdbc.queryForObject(sql.toString(), params, Long.class);
        return total == null ? 0L : total;
    }

    /** 列表的公共过滤条件。列统一带 {@code w.} 前缀，因为按标签查时是 JOIN。 */
    private static void appendConditions(StringBuilder sql, MapSqlParameterSource params,
                                         String workType, String titlePattern) {
        if (workType != null) {
            sql.append(" AND w.work_type = :workType");
            params.addValue("workType", workType);
        }
        if (titlePattern != null) {
            sql.append(" AND w.title LIKE :titlePattern ESCAPE '!'");
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
