package com.otaku.ugc;

import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.support.GeneratedKeyHolder;
import org.springframework.jdbc.support.KeyHolder;
import org.springframework.stereotype.Repository;

import java.time.LocalDateTime;
import java.util.Collection;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/**
 * ugc_comment 的读写。
 *
 * <p>所有查询都带 {@code site_key}：它是隔离的唯一依据，且**只从登录态取**
 * （{@code app_user.site_key}），不接受请求参数。少写一个 site_key，A 站的评论就会
 * 出现在 B 站作品页上——这条是红线，测试里有对应用例。
 *
 * <p>B2c 起本表同时存顶层评论与回复，靠 {@code parent_id} 区分（NULL = 顶层）。
 * 「列表」指的是顶层列表，回复单独按父查；两者都只认 {@code published}。
 */
@Repository
public class UgcRepository {

    /** 内部行：多带 username、状态与父 id，供列表渲染、删除鉴权与回复归档用。 */
    public record Row(
            long id,
            String siteKey,
            String workId,
            long userId,
            String username,
            String body,
            String status,
            LocalDateTime createdAt,
            Long parentId
    ) {
    }

    private static final RowMapper<Row> MAPPER = (rs, rowNum) -> new Row(
            rs.getLong("id"),
            rs.getString("site_key"),
            rs.getString("work_id"),
            rs.getLong("user_id"),
            rs.getString("username"),
            rs.getString("body"),
            rs.getString("status"),
            rs.getObject("created_at", LocalDateTime.class),
            rs.getObject("parent_id", Long.class));

    private final NamedParameterJdbcTemplate jdbc;

    public UgcRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public long insert(String siteKey, String workId, long userId, Long parentId, String body,
                       String status, LocalDateTime now) {
        KeyHolder keyHolder = new GeneratedKeyHolder();
        jdbc.update("""
                INSERT INTO ugc_comment (site_key, work_id, user_id, parent_id, body, status,
                                         created_at, updated_at)
                VALUES (:siteKey, :workId, :userId, :parentId, :body, :status, :now, :now)
                """, new MapSqlParameterSource()
                .addValue("siteKey", siteKey)
                .addValue("workId", workId)
                .addValue("userId", userId)
                .addValue("parentId", parentId)
                .addValue("body", body)
                .addValue("status", status)
                .addValue("now", now), keyHolder, new String[]{"id"});
        Number key = keyHolder.getKey();
        if (key == null) {
            throw new IllegalStateException("插入评论后拿不到自增主键");
        }
        return key.longValue();
    }

    /** 作品页顶层列表：只要 published 且 parent_id IS NULL，最新在前。 */
    public List<Row> findPublished(String siteKey, String workId, int limit, int offset) {
        return jdbc.query("""
                        SELECT c.id, c.site_key, c.work_id, c.user_id, u.username, c.body, c.status,
                               c.created_at, c.parent_id
                          FROM ugc_comment c
                          JOIN app_user u ON u.id = c.user_id
                         WHERE c.site_key = :siteKey AND c.work_id = :workId
                           AND c.parent_id IS NULL AND c.status = 'published'
                         ORDER BY c.created_at DESC, c.id DESC
                         LIMIT :limit OFFSET :offset
                        """, new MapSqlParameterSource()
                        .addValue("siteKey", siteKey)
                        .addValue("workId", workId)
                        .addValue("limit", limit)
                        .addValue("offset", offset), MAPPER);
    }

    /** 顶层评论数——列表 `total` 用它，回复不计入（回复数单独给 reply_count）。 */
    public long countPublished(String siteKey, String workId) {
        Long total = jdbc.queryForObject("""
                SELECT COUNT(*) FROM ugc_comment
                 WHERE site_key = :siteKey AND work_id = :workId
                   AND parent_id IS NULL AND status = 'published'
                """, new MapSqlParameterSource()
                .addValue("siteKey", siteKey)
                .addValue("workId", workId), Long.class);
        return total == null ? 0L : total;
    }

    /** 按 id 取一行（删除鉴权、回复挂载校验用）：同样带 site_key，跨站 id 直接当不存在。 */
    public Optional<Row> findById(String siteKey, long id) {
        List<Row> rows = jdbc.query("""
                SELECT c.id, c.site_key, c.work_id, c.user_id, u.username, c.body, c.status,
                       c.created_at, c.parent_id
                  FROM ugc_comment c
                  JOIN app_user u ON u.id = c.user_id
                 WHERE c.site_key = :siteKey AND c.id = :id
                """, new MapSqlParameterSource()
                .addValue("siteKey", siteKey)
                .addValue("id", id), MAPPER);
        return rows.stream().findFirst();
    }

    /**
     * 作者删除自己的评论：软删（status='deleted'），保留行以便追溯。
     * 只对 published / hidden 生效，重复删除不改变任何东西（幂等）。
     */
    public int markDeleted(String siteKey, long id, LocalDateTime now) {
        return jdbc.update("""
                UPDATE ugc_comment SET status = 'deleted', updated_at = :now
                 WHERE site_key = :siteKey AND id = :id AND status <> 'deleted'
                """, new MapSqlParameterSource()
                .addValue("siteKey", siteKey)
                .addValue("id", id)
                .addValue("now", now));
    }

    /**
     * 撤回一个楼层：顶层评论连同它下面的回复一起软删。
     *
     * <p>为什么连回复一起删：父评论没了，回复就失去上下文，单独留在公开列表里既读不懂、
     * 又会让「回复给已删除评论」出现在后台审核队列里。软删保留行，站主仍可追溯——
     * 不是把别人的话物理删掉。一层回复的设计让这条语句不会误伤其它楼层（parent_id 只有一层）。
     */
    public int markFloorDeleted(String siteKey, long id, LocalDateTime now) {
        return jdbc.update("""
                UPDATE ugc_comment SET status = 'deleted', updated_at = :now
                 WHERE site_key = :siteKey AND (id = :id OR parent_id = :id) AND status <> 'deleted'
                """, new MapSqlParameterSource()
                .addValue("siteKey", siteKey)
                .addValue("id", id)
                .addValue("now", now));
    }

    /** 某条顶层评论下的回复（对话顺序：最早在前）。 */
    public List<Row> findPublishedReplies(String siteKey, long parentId, int limit, int offset) {
        return jdbc.query("""
                        SELECT c.id, c.site_key, c.work_id, c.user_id, u.username, c.body, c.status,
                               c.created_at, c.parent_id
                          FROM ugc_comment c
                          JOIN app_user u ON u.id = c.user_id
                         WHERE c.site_key = :siteKey AND c.parent_id = :parentId
                           AND c.status = 'published'
                         ORDER BY c.created_at ASC, c.id ASC
                         LIMIT :limit OFFSET :offset
                        """, new MapSqlParameterSource()
                        .addValue("siteKey", siteKey)
                        .addValue("parentId", parentId)
                        .addValue("limit", limit)
                        .addValue("offset", offset), MAPPER);
    }

    public long countPublishedReplies(String siteKey, long parentId) {
        Long total = jdbc.queryForObject("""
                SELECT COUNT(*) FROM ugc_comment
                 WHERE site_key = :siteKey AND parent_id = :parentId AND status = 'published'
                """, new MapSqlParameterSource()
                .addValue("siteKey", siteKey)
                .addValue("parentId", parentId), Long.class);
        return total == null ? 0L : total;
    }

    /** 一批顶层评论各自的回复数（一次查完，避免列表 20 条打 20 次）。 */
    public Map<Long, Integer> countRepliesByParents(String siteKey, Collection<Long> parentIds) {
        if (parentIds.isEmpty()) {
            return Map.of();
        }
        Map<Long, Integer> counts = new HashMap<>();
        jdbc.query("""
                        SELECT parent_id, COUNT(*) AS c
                          FROM ugc_comment
                         WHERE site_key = :siteKey AND parent_id IN (:parentIds)
                           AND status = 'published'
                         GROUP BY parent_id
                        """, new MapSqlParameterSource()
                        .addValue("siteKey", siteKey)
                        .addValue("parentIds", parentIds),
                rs -> {
                    counts.put(rs.getLong("parent_id"), rs.getInt("c"));
                });
        return counts;
    }

    /**
     * 一批顶层评论各自的前 N 条回复（窗口函数一次查完）。
     *
     * <p>用 {@code ROW_NUMBER()} 而不是每条父查一次：列表页 20 条父评论就是 20 次往返，
     * 而评论区是客户端最高频的读路径之一。
     */
    public Map<Long, List<Row>> findRecentReplies(String siteKey, Collection<Long> parentIds,
                                                 int perParent) {
        if (parentIds.isEmpty()) {
            return Map.of();
        }
        Map<Long, List<Row>> grouped = new HashMap<>();
        jdbc.query("""
                        SELECT * FROM (
                            SELECT c.id, c.site_key, c.work_id, c.user_id, u.username, c.body, c.status,
                                   c.created_at, c.parent_id,
                                   ROW_NUMBER() OVER (PARTITION BY c.parent_id
                                                      ORDER BY c.created_at ASC, c.id ASC) AS rn
                              FROM ugc_comment c
                              JOIN app_user u ON u.id = c.user_id
                             WHERE c.site_key = :siteKey AND c.parent_id IN (:parentIds)
                               AND c.status = 'published'
                        ) t
                        WHERE t.rn <= :perParent
                        ORDER BY t.parent_id, t.created_at ASC, t.id ASC
                        """, new MapSqlParameterSource()
                        .addValue("siteKey", siteKey)
                        .addValue("parentIds", parentIds)
                        .addValue("perParent", perParent),
                rs -> {
                    Row row = MAPPER.mapRow(rs, 0);
                    grouped.computeIfAbsent(row.parentId(), k -> new java.util.ArrayList<>()).add(row);
                });
        return grouped;
    }

    /** 后台审核列表用的一行：比客户端多作品标题与父 id。 */
    public record ConsoleRow(
            long id,
            String siteKey,
            String workId,
            String workTitle,
            String username,
            String body,
            String status,
            LocalDateTime createdAt,
            Long parentId
    ) {
    }

    private static final RowMapper<ConsoleRow> CONSOLE_MAPPER = (rs, rowNum) -> new ConsoleRow(
            rs.getLong("id"),
            rs.getString("site_key"),
            rs.getString("work_id"),
            rs.getString("work_title"),
            rs.getString("username"),
            rs.getString("body"),
            rs.getString("status"),
            rs.getObject("created_at", LocalDateTime.class),
            rs.getObject("parent_id", Long.class));

    /**
     * 后台审核列表：按站点过滤，可按状态筛（null = 全部）。
     *
     * <p>排序用「最新在前」而不是「published 优先」：审核场景看的是刚发出来的，
     * 不是最好看的。
     */
    public List<ConsoleRow> findForConsole(String siteKey, String status, int limit, int offset) {
        StringBuilder sql = new StringBuilder("""
                SELECT c.id, c.site_key, c.work_id, COALESCE(w.title, c.work_id) AS work_title,
                       u.username, c.body, c.status, c.created_at, c.parent_id
                  FROM ugc_comment c
                  JOIN app_user u ON u.id = c.user_id
                  LEFT JOIN work w ON w.work_id = c.work_id
                 WHERE c.site_key = :siteKey
                """);
        MapSqlParameterSource params = new MapSqlParameterSource()
                .addValue("siteKey", siteKey)
                .addValue("limit", limit)
                .addValue("offset", offset);
        if (status != null) {
            sql.append(" AND c.status = :status");
            params.addValue("status", status);
        }
        sql.append(" ORDER BY c.created_at DESC, c.id DESC LIMIT :limit OFFSET :offset");
        return jdbc.query(sql.toString(), params, CONSOLE_MAPPER);
    }

    /** 单条（后台）：隐藏/恢复后要回一份带作品标题的最新状态。 */
    public Optional<ConsoleRow> findForConsoleById(String siteKey, long id) {
        return jdbc.query("""
                        SELECT c.id, c.site_key, c.work_id, COALESCE(w.title, c.work_id) AS work_title,
                               u.username, c.body, c.status, c.created_at, c.parent_id
                          FROM ugc_comment c
                          JOIN app_user u ON u.id = c.user_id
                          LEFT JOIN work w ON w.work_id = c.work_id
                         WHERE c.site_key = :siteKey AND c.id = :id
                        """,
                new MapSqlParameterSource().addValue("siteKey", siteKey).addValue("id", id),
                CONSOLE_MAPPER).stream().findFirst();
    }

    public long countForConsole(String siteKey, String status) {
        StringBuilder sql = new StringBuilder(
                "SELECT COUNT(*) FROM ugc_comment c WHERE c.site_key = :siteKey");
        MapSqlParameterSource params = new MapSqlParameterSource().addValue("siteKey", siteKey);
        if (status != null) {
            sql.append(" AND c.status = :status");
            params.addValue("status", status);
        }
        Long total = jdbc.queryForObject(sql.toString(), params, Long.class);
        return total == null ? 0L : total;
    }

    /** 后台改状态；只对存在的行生效，返回影响行数（0 = 不存在或跨站）。 */
    public int updateStatus(String siteKey, long id, String status, LocalDateTime now) {
        return jdbc.update("""
                UPDATE ugc_comment SET status = :status, updated_at = :now
                 WHERE site_key = :siteKey AND id = :id
                """, new MapSqlParameterSource()
                .addValue("siteKey", siteKey)
                .addValue("id", id)
                .addValue("status", status)
                .addValue("now", now));
    }

    /** 最近一段时间内该用户发了几条（防刷屏；回复与顶层共用同一额度，防止用回复绕过）。 */
    public int countRecentByUser(String siteKey, long userId, LocalDateTime since) {
        Integer count = jdbc.queryForObject("""
                SELECT COUNT(*) FROM ugc_comment
                 WHERE site_key = :siteKey AND user_id = :userId AND created_at >= :since
                   AND status <> 'deleted'
                """, new MapSqlParameterSource()
                .addValue("siteKey", siteKey)
                .addValue("userId", userId)
                .addValue("since", since), Integer.class);
        return count == null ? 0 : count;
    }
}
