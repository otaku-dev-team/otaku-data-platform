package com.otaku.mockseed;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Random;

/**
 * 模拟用户行为数据种子（#415）。
 *
 * <p>给「开发期没有真实用户行为」这件事兜底：画像（#401）/ 推荐（#402）/ 统一服务（#413）
 * 需要燃料才能端到端跑通、调参、评估，而生产上 `collection` / `ugc_review` / `user_work_view` 都是 0 行。
 *
 * <p><b>红线</b>：
 * <ul>
 *   <li>只写 {@code app_user} / {@code user_work_view} / {@code collection} / {@code ugc_review}，
 *       不动作品与标签；</li>
 *   <li>mock 用户以 {@code identity_source='mock'} 标记，清空只按这个标记删，**不碰真实用户**；</li>
 *   <li>可重复执行：先按标记清空再写入，同参数两次结果同分布。</li>
 * </ul>
 *
 * <p>「只在 dev 生效」这道门由 {@link MockSeedRunner} 把守——服务本身不判断 profile，
 * 否则单测与集成测试没法直接调它。
 */
@Service
public class MockSeedService {

    private static final Logger log = LoggerFactory.getLogger(MockSeedService.class);

    /** mock 用户的标记值：清理与统计都认它。 */
    static final String MOCK_MARK = "mock";

    private static final int BATCH = 500;

    private final NamedParameterJdbcTemplate namedJdbc;
    private final JdbcTemplate jdbc;

    public MockSeedService(NamedParameterJdbcTemplate namedJdbc, JdbcTemplate jdbc) {
        this.namedJdbc = namedJdbc;
        this.jdbc = jdbc;
    }

    /** 一次种子的结果，日志与测试断言都用它。 */
    public record Result(int users, int views, int collections, int reviews) {
    }

    /**
     * 先清后种；{@code users <= 0} 等于只清空。
     *
     * @param days 行为发生在最近多少天内
     */
    public Result seed(int users, long randomSeed, int days) {
        int cleared = clear();
        if (cleared > 0) {
            log.info("清掉上一批 mock 用户 {} 个及其行为", cleared);
        }
        if (users <= 0) {
            return new Result(0, 0, 0, 0);
        }

        List<TagWeight> vocabulary = topTags(200);
        if (vocabulary.isEmpty()) {
            throw new IllegalStateException("标签词表为空：先导入作品，再种 mock 数据");
        }
        List<WorkRef> popular = popularWorks(400);
        if (popular.isEmpty()) {
            throw new IllegalStateException("没有可见作品：先导入作品，再种 mock 数据");
        }
        Map<String, List<WorkRef>> byTag = worksByTag(vocabulary.stream().map(TagWeight::tag).toList());
        Map<String, String> sourceToSite = sourceSites();
        // 站点的唯一来源是 site 表（app_user.site_key 有外键指着它）。
        // 不写死站名：这个后端是白标的，check-site-isolation 会拦；dev 库里有什么站点就用什么。
        String defaultSiteKey = activeSiteKey();
        if (defaultSiteKey == null) {
            log.warn("库里没有任何 active 站点：mock 用户不带 site_key，且不写评分（ugc_review 要求站点非空）");
        }

        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        MockTasteGenerator rng = new MockTasteGenerator(randomSeed);

        // 1) 用户先落库，拿到内部主键后再写行为（行为表按 user_id 关联，不是 username）
        List<Object[]> userRows = new ArrayList<>(users);
        for (int i = 0; i < users; i++) {
            String username = "mock-" + String.format("%04d", i + 1);
            userRows.add(new Object[]{username, username, "mock-no-login", now, now,
                    defaultSiteKey, "active", MOCK_MARK});
        }
        jdbc.batchUpdate("""
                INSERT INTO app_user (user_id, username, password_hash, created_at, updated_at,
                                      site_key, status, identity_source)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, userRows);

        Map<String, Long> userIds = new HashMap<>();
        jdbc.query("SELECT id, username FROM app_user WHERE identity_source = ?",
                rs -> { userIds.put(rs.getString("username"), rs.getLong("id")); }, MOCK_MARK);

        // 2) 行为
        List<Object[]> views = new ArrayList<>();
        List<Object[]> collections = new ArrayList<>();
        List<Object[]> reviews = new ArrayList<>();
        List<String> tagNames = vocabulary.stream().map(TagWeight::tag).toList();
        List<Integer> tagWeights = vocabulary.stream().map(TagWeight::count).toList();

        for (int i = 0; i < users; i++) {
            String username = "mock-" + String.format("%04d", i + 1);
            Long userId = userIds.get(username);
            if (userId == null) {
                continue;
            }
            int tasteSize = 2 + rng.viewCount(0, 2);
            List<String> taste = rng.pickTaste(tagNames, tagWeights, tasteSize);
            List<Map.Entry<WorkRef, Integer>> menu =
                    tasteMenu(taste, byTag, popular, rng, randomSeed + i);
            int viewCount = Math.min(rng.viewCount(8, 40), menu.size());

            for (int v = 0; v < viewCount; v++) {
                WorkRef work = menu.get(v).getKey();
                int hits = menu.get(v).getValue();
                LocalDateTime at = now.minusNanos(rng.millisAgo(days) * 1_000_000L);
                views.add(new Object[]{userId, work.workId(), at, at});
                if (rng.collect(0.25)) {
                    LocalDateTime collected = now.minusNanos(rng.millisAgo(days) * 1_000_000L);
                    collections.add(new Object[]{userId, work.workId(),
                            rng.collect(0.5) ? "watching" : "want", collected, collected});
                }
                if (rng.collect(0.18)) {
                    double rating = rng.rating(hits);
                    String siteKey = sourceToSite.getOrDefault(work.source(), defaultSiteKey);
                    if (siteKey == null) {
                        continue;   // 没有站点可归属就不写评分，别造一条 site_key 为空的行
                    }
                    LocalDateTime rated = now.minusNanos(rng.millisAgo(days) * 1_000_000L);
                    reviews.add(new Object[]{siteKey, work.workId(), userId, rating, rated, rated});
                }
            }
        }

        int viewRows = batch("""
                INSERT INTO user_work_view (user_id, work_id, first_viewed_at, last_viewed_at, view_count)
                VALUES (?, ?, ?, ?, 1)
                ON DUPLICATE KEY UPDATE last_viewed_at = VALUES(last_viewed_at)
                """, views);

        int collectionRows = batch("""
                INSERT IGNORE INTO collection (user_id, work_id, status, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """, collections);

        int reviewRows = batch("""
                INSERT INTO ugc_review (site_key, work_id, user_id, rating, body, status, created_at, updated_at)
                VALUES (?, ?, ?, ?, NULL, 'published', ?, ?)
                """, reviews);

        log.info("mock 种子完成：users={} views={} collections={} reviews={}（最近 {} 天，seed={}）",
                users, viewRows, collectionRows, reviewRows, days, randomSeed);
        return new Result(users, viewRows, collectionRows, reviewRows);
    }

    /** 只清 mock 数据：真实用户与他们的行为一条都不碰。返回清掉的 mock 用户数。 */
    public int clear() {
        List<Long> ids = jdbc.queryForList(
                "SELECT id FROM app_user WHERE identity_source = ?", Long.class, MOCK_MARK);
        if (ids.isEmpty()) {
            return 0;
        }
        MapSqlParameterSource params = new MapSqlParameterSource("ids", ids);
        namedJdbc.update("DELETE FROM user_work_view WHERE user_id IN (:ids)", params);
        namedJdbc.update("DELETE FROM collection WHERE user_id IN (:ids)", params);
        namedJdbc.update("DELETE FROM ugc_review WHERE user_id IN (:ids)", params);
        namedJdbc.update("DELETE FROM app_user WHERE id IN (:ids)", params);
        return ids.size();
    }

    public int countMockUsers() {
        Integer n = jdbc.queryForObject(
                "SELECT COUNT(*) FROM app_user WHERE identity_source = ?", Integer.class, MOCK_MARK);
        return n == null ? 0 : n;
    }

    // ── 查询与批量写入 ──────────────────────────────────────────────

    private record TagWeight(String tag, int count) {
    }

    record WorkRef(String workId, String source) {
    }

    private List<TagWeight> topTags(int limit) {
        return jdbc.query(
                "SELECT tag, COUNT(*) AS c FROM work_tag"
                        + " GROUP BY tag ORDER BY c DESC LIMIT ?",
                (rs, i) -> new TagWeight(rs.getString("tag"), rs.getInt("c")), limit);
    }

    private List<WorkRef> popularWorks(int limit) {
        return jdbc.query(
                "SELECT work_id, source FROM work WHERE deleted_at IS NULL"
                        + " AND is_adult = 0 ORDER BY rating_count DESC, id DESC LIMIT ?",
                (rs, i) -> new WorkRef(rs.getString("work_id"), rs.getString("source")), limit);
    }

    private Map<String, List<WorkRef>> worksByTag(List<String> tags) {
        Map<String, List<WorkRef>> map = new HashMap<>();
        if (tags.isEmpty()) {
            return map;
        }
        namedJdbc.query("SELECT t.tag, w.work_id, w.source FROM work_tag t JOIN work w ON w.id = t.work_ref"
                        + " WHERE t.tag IN (:tags) AND w.deleted_at IS NULL"
                        + " AND w.is_adult = 0",
                new MapSqlParameterSource("tags", tags),
                rs -> {
                    map.computeIfAbsent(rs.getString("tag"), k -> new ArrayList<>())
                            .add(new WorkRef(rs.getString("work_id"), rs.getString("source")));
                });
        return map;
    }

    /** 库里的 active 站点（白标：不写死名字，有什么用什么）。 */
    private String activeSiteKey() {
        List<String> keys = jdbc.queryForList(
                "SELECT site_key FROM site WHERE status = 'active' ORDER BY site_key LIMIT 1", String.class);
        return keys.isEmpty() ? null : keys.get(0);
    }

    private Map<String, String> sourceSites() {
        Map<String, String> map = new LinkedHashMap<>();
        jdbc.query("SELECT source, site_key FROM site_source",
                rs -> { map.put(rs.getString("source"), rs.getString("site_key")); });
        return map;
    }

    /**
     * 口味菜单：口味标签下的作品（记下「命中几个口味标签」）+ 少量全站热门（命中 0）。
     *
     * <p>返回 map 而不是 list：命中数是评分的输入（口味越对分数越高），
     * 事后再去反查「这部作品属于哪几个口味标签」要么慢、要么又写一遍同样的循环。
     */
    private List<Map.Entry<WorkRef, Integer>> tasteMenu(List<String> taste,
                                                        Map<String, List<WorkRef>> byTag,
                                                        List<WorkRef> popular,
                                                        MockTasteGenerator rng,
                                                        long shuffleSeed) {
        Map<String, WorkRef> works = new LinkedHashMap<>();
        Map<String, Integer> hits = new HashMap<>();

        for (String tag : taste) {
            for (WorkRef ref : byTag.getOrDefault(tag, List.of())) {
                if (works.size() >= 60) {
                    break;
                }
                if (rng.collect(0.05)) {
                    works.putIfAbsent(ref.workId(), ref);
                    hits.merge(ref.workId(), 1, Integer::sum);
                }
            }
        }
        for (WorkRef ref : popular) {
            if (works.size() >= 60) {
                break;
            }
            if (rng.collect(0.03)) {
                works.putIfAbsent(ref.workId(), ref);
                hits.putIfAbsent(ref.workId(), 0);
            }
        }

        List<WorkRef> shuffled = new ArrayList<>(works.values());
        Collections.shuffle(shuffled, new Random(shuffleSeed));
        List<Map.Entry<WorkRef, Integer>> menu = new ArrayList<>(shuffled.size());
        for (WorkRef ref : shuffled) {
            menu.add(Map.entry(ref, hits.getOrDefault(ref.workId(), 0)));
        }
        return menu;
    }

    private int batch(String sql, List<Object[]> rows) {
        if (rows.isEmpty()) {
            return 0;
        }
        int total = 0;
        for (int start = 0; start < rows.size(); start += BATCH) {
            List<Object[]> slice = rows.subList(start, Math.min(start + BATCH, rows.size()));
            total += jdbc.batchUpdate(sql, slice).length;
        }
        return total;
    }
}
