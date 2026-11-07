package com.otaku.articlefavorite;

import com.otaku.article.ArticleRecord;
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
 * 资讯收藏的读写（#377）。
 *
 * <p>所有方法都强制带 {@code user_id}：与作品收藏同一条验收口径——用户只能看到
 * 自己的数据，user_id 只从会话取，任何接口都不接受客户端传入。
 *
 * <p>列表与计数都 JOIN {@code article}：资讯若已不在表里，收藏行不该继续占位，
 * 否则会出现「共 12 条、只翻到 10 条」的计数与列表不一致。
 */
@Repository
public class ArticleFavoriteRepository {

    /**
     * 列表只取资讯卡需要的列，**不取 body**：正文可能几 KB，收藏页只渲染摘要；
     * 少读一列就少一次大字段的行外读取。
     */
    private static final String ARTICLE_COLUMNS = """
            a.id, a.article_id, a.source, a.source_id, a.title, a.summary, a.category,
            a.published_at, a.source_name, a.source_url, a.cover_url, a.tags,
            a.created_at, a.updated_at
            """;

    private static final RowMapper<FavoriteRow> MAPPER = ArticleFavoriteRepository::map;

    private final NamedParameterJdbcTemplate jdbc;

    public ArticleFavoriteRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /** 单条收藏时间；未收藏返回空。资讯是否存在由 service 先判（404 口径不在这里）。 */
    public Optional<LocalDateTime> findFavoritedAt(long userPk, String articleId) {
        List<LocalDateTime> rows = jdbc.query(
                "SELECT created_at FROM article_favorite"
                        + " WHERE user_id = :userId AND article_id = :articleId",
                new MapSqlParameterSource()
                        .addValue("userId", userPk)
                        .addValue("articleId", articleId),
                (rs, rowNum) -> rs.getObject("created_at", LocalDateTime.class));
        return rows.stream().findFirst();
    }

    /**
     * 幂等 upsert：不存在则创建，已存在只推进 {@code updated_at}。
     *
     * <p>重复提交不产生第二条记录（唯一键兜底），也不用先查后写——
     * 两个并发 PUT 在唯一键上收敛，后到的把时间推进到更晚，结果仍一致。
     */
    public void upsert(long userPk, String articleId, LocalDateTime now) {
        jdbc.update("""
                        INSERT INTO article_favorite (user_id, article_id, created_at, updated_at)
                        VALUES (:userId, :articleId, :now, :now)
                        ON DUPLICATE KEY UPDATE updated_at = :now
                        """,
                new MapSqlParameterSource()
                        .addValue("userId", userPk)
                        .addValue("articleId", articleId)
                        .addValue("now", now));
    }

    /** 幂等删除：不存在也返回 0，不报错。 */
    public int delete(long userPk, String articleId) {
        return jdbc.update(
                "DELETE FROM article_favorite WHERE user_id = :userId AND article_id = :articleId",
                new MapSqlParameterSource()
                        .addValue("userId", userPk)
                        .addValue("articleId", articleId));
    }

    /**
     * 分页列表。排序固定 {@code updated_at DESC, article_id ASC}——
     * 第二个键保证同一毫秒写入的多条记录翻页时不跳条。
     */
    public List<FavoriteRow> findPage(long userPk, int limit, int offset) {
        return jdbc.query(
                "SELECT " + ARTICLE_COLUMNS + ", f.created_at AS favorited_at"
                        + "  FROM article_favorite f"
                        + "  JOIN article a ON a.article_id = f.article_id"
                        + " WHERE f.user_id = :userId"
                        + " ORDER BY f.updated_at DESC, f.article_id ASC"
                        + " LIMIT :limit OFFSET :offset",
                new MapSqlParameterSource()
                        .addValue("userId", userPk)
                        .addValue("limit", limit)
                        .addValue("offset", offset),
                MAPPER);
    }

    /** 与 {@link #findPage} 同一 JOIN 口径，避免「计数含孤儿行、列表不含」。 */
    public long count(long userPk) {
        Long total = jdbc.queryForObject(
                "SELECT COUNT(*) FROM article_favorite f"
                        + " JOIN article a ON a.article_id = f.article_id"
                        + " WHERE f.user_id = :userId",
                new MapSqlParameterSource("userId", userPk),
                Long.class);
        return total == null ? 0 : total;
    }

    private static FavoriteRow map(ResultSet rs, int rowNum) throws SQLException {
        // body / related_work_ids 是详情字段，收藏列表刻意不读（理由见 ARTICLE_COLUMNS），
        // 这里给 null；ArticleSummary 不消费它们。
        ArticleRecord article = new ArticleRecord(
                rs.getLong("id"),
                rs.getString("article_id"),
                rs.getString("source"),
                rs.getString("source_id"),
                rs.getString("title"),
                rs.getString("summary"),
                null,
                rs.getString("category"),
                rs.getObject("published_at", LocalDateTime.class),
                rs.getString("source_name"),
                rs.getString("source_url"),
                rs.getString("cover_url"),
                rs.getString("tags"),
                null,
                rs.getObject("created_at", LocalDateTime.class),
                rs.getObject("updated_at", LocalDateTime.class));
        return new FavoriteRow(article, rs.getObject("favorited_at", LocalDateTime.class));
    }

    /** 一条收藏 = 资讯本体 + 收藏时间。 */
    public record FavoriteRow(ArticleRecord article, LocalDateTime favoritedAt) {
    }
}
