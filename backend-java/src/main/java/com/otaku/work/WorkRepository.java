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
            title_original, aliases, media, episodes,
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

    public long insert(WorkRecord record) {
        String sql = """
                INSERT INTO work (work_id, work_type, title, summary, release_year,
                                  title_original, aliases, media, episodes,
                                  cover_source_url, cover_cache_key, cover_cached_at,
                                  tags, rating_value, rating_scale, rating_source,
                                  source, source_id, source_url, created_at, updated_at)
                VALUES (:workId, :workType, :title, :summary, :releaseYear,
                        :titleOriginal, :aliasesJson, :media, :episodes,
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
        return key.longValue();
    }

    /** 只推进 updated_at：关系数据（staff/characters/studios）变了、内容字段没变时用。 */
    public void touch(long id, LocalDateTime now) {
        jdbc.update("UPDATE work SET updated_at = :now WHERE id = :id",
                new MapSqlParameterSource().addValue("id", id).addValue("now", now));
    }

    /** 只更新内容字段；work_id / source / source_id / created_at 永不变。 */
    public void updateContent(WorkRecord record) {
        String sql = """
                UPDATE work SET title = :title,
                                summary = :summary,
                                release_year = :releaseYear,
                                title_original = :titleOriginal,
                                aliases = :aliasesJson,
                                media = :media,
                                episodes = :episodes,
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
     * <p>带标签时内层换成查 {@code work_tag}：那两张索引里冗余了评分与年份，
     * 所以「标签 + 评分/年份排序」仍是有序扫描，不需要 filesort（35ms vs 772ms）。
     * 代价是标签内跳深页仍受 OFFSET 影响，与主表一致。
     *
     * <p>单标签走上面那条索引有序路径；**多标签走 {@code tag IN (...)} + GROUP BY ...
     * HAVING COUNT(DISTINCT tag) = n**（AND 语义）。多标签天然是集合运算，
     * 无法再靠单标签索引保证顺序，排序会多一次 filesort——这是 AND 语义的固有成本，
     * 不是实现缺陷；词表规模小、标签组合有限，实测代价可接受。
     */
    public List<WorkRecord> findPage(String workType, String titlePattern, List<String> tags, WorkSort sort,
                                     BigDecimal minRating, Integer year, int limit, int offset) {
        MapSqlParameterSource params = new MapSqlParameterSource()
                .addValue("limit", limit)
                .addValue("offset", offset);
        WorkSort effective = sort == null ? WorkSort.ID : sort;

        StringBuilder inner;
        if (tags == null || tags.isEmpty()) {
            inner = new StringBuilder("SELECT w.id AS id FROM work w WHERE 1 = 1");
            appendConditions(inner, params, workType, titlePattern, minRating, year);
            inner.append(" ORDER BY ").append(effective.orderBy("w"));
        } else if (tags.size() == 1) {
            // 走关联表：标签条件的成本与标签基数成正比，而不是与全表成正比。
            params.addValue("tag", tags.get(0));
            // 只有标题关键词必须回表（title 不在 work_tag 里）；类型已经冗余进索引。
            // 为取 id 而回表是纯浪费：55.6 万条实测，`COUNT(*) ... JOIN work` 296ms
            // （46,000 次随机回表），纯索引扫描只要个位数毫秒。
            if (titlePattern != null) {
                inner = new StringBuilder("SELECT t.work_ref AS id FROM work_tag t"
                        + " JOIN work w ON w.id = t.work_ref WHERE t.tag = :tag");
                appendConditions(inner, params, workType, titlePattern, minRating, year);
            } else {
                inner = new StringBuilder("SELECT t.work_ref AS id FROM work_tag t WHERE t.tag = :tag");
                appendTagConditions(inner, params, workType, minRating, year);
            }
            inner.append(" ORDER BY ").append(effective.orderByOnTagTable("t"));
        } else {
            inner = multiTagSelect(params, workType, titlePattern, tags, minRating, year);
            inner.append(" GROUP BY t.work_ref")
                    .append(" HAVING COUNT(DISTINCT t.tag) = :tagCount")
                    .append(" ORDER BY ").append(effective.orderByOnTagAggregate("t"));
        }
        inner.append(" LIMIT :limit OFFSET :offset");

        String sql = "SELECT " + ALIASED_COLUMNS + " FROM work w"
                + " JOIN (" + inner + ") p ON p.id = w.id"
                + " ORDER BY " + effective.orderBy("w");
        return jdbc.query(sql, params, MAPPER);
    }

    /**
     * 多标签查询的 FROM/WHERE 部分（AND 语义由调用方追加 GROUP BY + HAVING 完成）。
     *
     * <p>{@code tag IN (:tags)} 会按每个标签各做一次索引范围扫描，再合并；
     * 条件用 {@code work_tag} 的冗余列（`work_type` / `rating_value`），
     * 只有标题关键词必须回表。
     */
    private static StringBuilder multiTagSelect(MapSqlParameterSource params, String workType,
                                                String titlePattern, List<String> tags,
                                                BigDecimal minRating, Integer year) {
        params.addValue("tags", tags);
        params.addValue("tagCount", tags.size());
        StringBuilder sql = new StringBuilder("SELECT t.work_ref AS id FROM work_tag t");
        if (titlePattern != null) {
            sql.append(" JOIN work w ON w.id = t.work_ref");
        }
        sql.append(" WHERE t.tag IN (:tags)");
        appendTagConditions(sql, params, workType, minRating, year);
        if (titlePattern != null) {
            sql.append(" AND w.title LIKE :titlePattern");
            params.addValue("titlePattern", titlePattern);
        }
        return sql;
    }

    /** 落在 {@code work_tag} 冗余列上的过滤条件（类型 / 评分下限）。 */
    private static void appendTagConditions(StringBuilder sql, MapSqlParameterSource params,
                                            String workType, BigDecimal minRating, Integer year) {
        if (workType != null) {
            sql.append(" AND t.work_type = :workType");
            params.addValue("workType", workType);
        }
        if (minRating != null) {
            // 用冗余列而不是回表比 w.rating_value：(tag, rating_value, work_ref) 上
            // 一次范围扫描就够，还能顺带满足 sort=rating 的顺序。
            sql.append(" AND t.rating_value >= :minRating");
            params.addValue("minRating", minRating);
        }
        if (year != null) {
            // 用冗余列：idx_work_tag_year (tag, release_year, work_ref) 直接可用，不必回表。
            sql.append(" AND t.release_year = :year");
            params.addValue("year", year);
        }
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

    public long count(String workType, String titlePattern, List<String> tags, BigDecimal minRating,
                      Integer year) {
        MapSqlParameterSource params = new MapSqlParameterSource();
        StringBuilder sql;
        if (tags == null || tags.isEmpty()) {
            sql = new StringBuilder("SELECT COUNT(*) FROM work w WHERE 1 = 1");
            appendConditions(sql, params, workType, titlePattern, minRating, year);
        } else if (tags.size() == 1) {
            params.addValue("tag", tags.get(0));
            // 同 findPage：标题必须回表；类型已冗余进 work_tag，不必 JOIN。
            if (titlePattern != null) {
                sql = new StringBuilder("SELECT COUNT(*) FROM work_tag t"
                        + " JOIN work w ON w.id = t.work_ref WHERE t.tag = :tag");
                appendConditions(sql, params, workType, titlePattern, minRating, year);
            } else {
                sql = new StringBuilder("SELECT COUNT(*) FROM work_tag t WHERE t.tag = :tag");
                appendTagConditions(sql, params, workType, minRating, year);
            }
        } else {
            // 多标签：先按 work_ref 分组数出"命中了几个标签"，再取满足 n 个的组数。
            StringBuilder inner = multiTagSelect(params, workType, titlePattern, tags, minRating, year);
            inner.append(" GROUP BY t.work_ref HAVING COUNT(DISTINCT t.tag) = :tagCount");
            sql = new StringBuilder("SELECT COUNT(*) FROM (").append(inner).append(") matched");
        }
        Long total = jdbc.queryForObject(sql.toString(), params, Long.class);
        return total == null ? 0L : total;
    }

    /** 列表的公共过滤条件。列统一带 {@code w.} 前缀，因为按标签查时是 JOIN。 */
    private static void appendConditions(StringBuilder sql, MapSqlParameterSource params,
                                         String workType, String titlePattern, BigDecimal minRating,
                                         Integer year) {
        if (workType != null) {
            sql.append(" AND w.work_type = :workType");
            params.addValue("workType", workType);
        }
        if (titlePattern != null) {
            sql.append(" AND w.title LIKE :titlePattern ESCAPE '!'");
            params.addValue("titlePattern", titlePattern);
        }
        if (minRating != null) {
            // 榜单语义：只要评分 ≥ 下限的作品。NULL 与任何数比较都不成立，
            // 无评分作品因此被自然排除——不需要额外写 IS NOT NULL。
            sql.append(" AND w.rating_value >= :minRating");
            params.addValue("minRating", minRating);
        }
        if (year != null) {
            // 等值匹配：没有年份的作品不混进任何一年。
            // 走 idx_work_year (release_year, ...) 的范围扫描，不需要 filesort 之外的成本。
            sql.append(" AND w.release_year = :year");
            params.addValue("year", year);
        }
    }

    private static MapSqlParameterSource baseParams(WorkRecord record) {
        return new MapSqlParameterSource()
                .addValue("workId", record.workId())
                .addValue("workType", record.workType())
                .addValue("title", record.title())
                .addValue("summary", record.summary())
                .addValue("releaseYear", record.releaseYear())
                .addValue("titleOriginal", record.titleOriginal())
                .addValue("aliasesJson", record.aliasesJson())
                .addValue("media", record.media())
                .addValue("episodes", record.episodes())
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
                rs.getString("title_original"),
                TagsJson.canonical(rs.getString("aliases")),
                rs.getString("media"),
                rs.getObject("episodes", Integer.class),
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
