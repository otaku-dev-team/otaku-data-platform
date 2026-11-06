package com.otaku.recommend;

import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * 推荐需要的个人数据：用户已经接触过的作品。
 *
 * <p>为什么不复用画像：画像是「偏好摘要」，`recent_active` 只保留最近 30 天、最多 20 个，
 * 用它排除已看会漏掉大量老记录——用户会看到自己半年前看完的片子被推荐回来。
 * 这里要的是**全量**已看/已收藏集合，直接从两张个人表取。
 */
@Repository
public class RecommendRepository {

    private final NamedParameterJdbcTemplate jdbc;

    public RecommendRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /**
     * 用户已浏览或已收藏的作品 id 集合。
     *
     * <p>两表 `UNION`（不是 `UNION ALL`）：同一部作品既看过又收藏时只算一条。
     * 行数 = 用户行为过的作品数，正常量级几百到几千，一次取回内存判断比在 SQL 里
     * 拼 `NOT IN (...)` 更稳（后者在候选多时会撞参数上限）。
     */
    public Set<String> touchedWorkIds(long userId) {
        List<String> ids = jdbc.queryForList(
                "SELECT work_id FROM user_work_view WHERE user_id = :userId"
                        + " UNION "
                        + "SELECT work_id FROM collection WHERE user_id = :userId",
                Map.of("userId", userId),
                String.class);
        return new HashSet<>(ids);
    }
}
