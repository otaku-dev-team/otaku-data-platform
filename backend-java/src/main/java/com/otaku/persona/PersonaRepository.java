package com.otaku.persona;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;

/**
 * 画像信号读取：把用户的浏览 / 收藏 / 点评三路合成一张「行为行」表。
 *
 * <p>为什么一次 UNION ALL 而不是发三条查询：三路都要 join `work` 拿类型与标签，
 * 分三次查会有 2 次重复往返；行数上限是「用户看过的作品数」，本来就不大。
 *
 * <p>为什么没有 `site_key` 过滤：`app_user` 本身归属一个站点（V10），一个账号的行为不会跨站；
 * 点评表虽然带 `site_key`，但按 `user_id` 过滤已经等价。等真出现「一个账号跨多站」再补，
 * 现在加只会让 SQL 多一个恒真条件。
 */
@Repository
public class PersonaRepository {

    private static final TypeReference<List<String>> TAG_LIST = new TypeReference<>() {
    };

    private final NamedParameterJdbcTemplate jdbc;
    private final ObjectMapper objectMapper;

    public PersonaRepository(NamedParameterJdbcTemplate jdbc, ObjectMapper objectMapper) {
        this.jdbc = jdbc;
        this.objectMapper = objectMapper;
    }

    /**
     * 取一个用户的行为行，**按时间倒序**、最多 `limit` 条。
     *
     * <p>排序放在外层子查询外面：三路各自没有顺序，客户端要的「最近活跃」依赖整体顺序，
     * 在 SQL 里排一次比在 Java 里再排一次省事，也能让 LIMIT 真正截到「最近的 N 条」。
     */
    public List<SignalRow> findSignals(long userId, int limit) {
        String sql = """
                SELECT * FROM (
                    SELECT v.work_id          AS work_id,
                           w.work_type        AS work_type,
                           w.tags             AS tags,
                           'view'             AS kind,
                           v.view_count       AS view_count,
                           NULL               AS collection_status,
                           NULL               AS rating,
                           v.last_viewed_at   AS happened_at
                    FROM user_work_view v
                    JOIN work w ON w.work_id = v.work_id
                    WHERE v.user_id = :userId
                    UNION ALL
                    SELECT c.work_id,
                           w.work_type,
                           w.tags,
                           'collection',
                           0,
                           c.status,
                           NULL,
                           c.updated_at
                    FROM collection c
                    JOIN work w ON w.work_id = c.work_id
                    WHERE c.user_id = :userId
                    UNION ALL
                    SELECT r.work_id,
                           w.work_type,
                           w.tags,
                           'review',
                           0,
                           NULL,
                           r.rating,
                           r.updated_at
                    FROM ugc_review r
                    JOIN work w ON w.work_id = r.work_id
                    WHERE r.user_id = :userId
                      AND r.status <> 'deleted'
                ) signals
                ORDER BY happened_at DESC
                LIMIT :limit
                """;
        return jdbc.query(sql, Map.of("userId", userId, "limit", limit),
                (rs, rowNum) -> new SignalRow(
                        rs.getString("work_id"),
                        rs.getString("work_type"),
                        parseTags(rs.getString("tags")),
                        rs.getString("kind"),
                        rs.getInt("view_count"),
                        rs.getString("collection_status"),
                        (Integer) rs.getObject("rating"),
                        rs.getObject("happened_at", LocalDateTime.class)));
    }

    /** 标签列是 JSON；解析失败按「无标签」处理——画像不该因为一条脏 tags 整体 500。 */
    private List<String> parseTags(String json) {
        if (json == null || json.isBlank()) {
            return List.of();
        }
        try {
            return objectMapper.readValue(json, TAG_LIST);
        } catch (Exception ex) {
            return List.of();
        }
    }

    /**
     * 一行行为。`kind` 决定权重怎么算：
     * `view` 看 `viewCount`，`collection` 看 `collectionStatus`，`review` 看 `rating`。
     */
    public record SignalRow(
            String workId,
            String workType,
            List<String> tags,
            String kind,
            int viewCount,
            String collectionStatus,
            Integer rating,
            LocalDateTime happenedAt
    ) {
    }
}
