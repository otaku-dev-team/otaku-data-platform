package com.otaku.work;

import com.otaku.common.AdultPolicy;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;

/**
 * 按当前配置重算全库成人标记（{@code work.is_adult} / {@code work_tag.is_adult}）。
 *
 * <p>什么时候跑：改了 {@code adult.*} 配置之后（{@code PUT /internal/app/config} 会自动触发），
 * 或手工兜底。**只在有人改配置时跑**，平时全靠导入路径增量维护——否则每次导入都要扫全表。
 *
 * <p>为什么是全量重算而不是增量：词表一改，「哪些作品命中」整张表都可能变（删词要放开一批、
 * 加词要藏起一批），增量比对的复杂度远高于直接重算。实测 19.8 万部 / 49.9 万行，
 * 全量两轮 UPDATE 在秒级，属于可接受的一次性运维成本。
 *
 * <p>{@code synchronized}：并发重算会互相覆盖中间状态（A 清空、B 打标、A 再打标…），
 * 而这是低频运维动作，串行没有代价。
 */
@Component
public class AdultFlagRebuilder {

    private static final Logger log = LoggerFactory.getLogger(AdultFlagRebuilder.class);

    private final JdbcTemplate jdbc;
    private final AdultPolicy policy;
    private final TagCache tagCache;
    private final CountCache countCache;

    public AdultFlagRebuilder(JdbcTemplate jdbc, AdultPolicy policy, TagCache tagCache, CountCache countCache) {
        this.jdbc = jdbc;
        this.policy = policy;
        this.tagCache = tagCache;
        this.countCache = countCache;
    }

    /**
     * @param enabled     本次重建时遮挡是否开着（false = 全库清零）
     * @param hiddenWorks 重建后仍被隐藏的作品数
     * @param tagRows     work_tag 里实际改动的行数
     */
    public record Result(boolean enabled, long hiddenWorks, int tagRows, long millis) {
    }

    public synchronized Result rebuild() {
        long start = System.nanoTime();

        // 先只清「原来是 1」的行：全表 SET 0 会把 19 万行都写一遍，而其中 96% 本来就没变
        jdbc.update("UPDATE work SET is_adult = 0 WHERE is_adult = 1");

        if (policy.hidden()) {
            jdbc.update("UPDATE work SET is_adult = 1"
                            + " WHERE tags IS NOT NULL AND JSON_OVERLAPS(tags, CAST(? AS JSON))",
                    policy.tagsJson());

            List<String> markers = policy.titleMarkers();
            if (!markers.isEmpty()) {
                List<Object> args = new ArrayList<>(markers.size());
                StringBuilder condition = new StringBuilder();
                for (String marker : markers) {
                    if (condition.length() > 0) {
                        condition.append(" OR ");
                    }
                    condition.append("title LIKE ?");
                    args.add("%" + escapeLike(marker) + "%");
                }
                jdbc.update("UPDATE work SET is_adult = 1 WHERE " + condition, args.toArray());
            }
        }

        // 冗余列只同步真正变化的行：词表小改时通常是几百到几千行
        int tagRows = jdbc.update("UPDATE work_tag t JOIN work w ON w.id = t.work_ref"
                + " SET t.is_adult = w.is_adult WHERE t.is_adult <> w.is_adult");

        Long hidden = jdbc.queryForObject("SELECT COUNT(*) FROM work WHERE is_adult = 1", Long.class);

        // 词表与计数都依赖 is_adult，重建后必须失效，否则要等下一次导入才更新
        tagCache.invalidateAll();
        countCache.invalidateAll();

        long millis = (System.nanoTime() - start) / 1_000_000;
        Result result = new Result(policy.hidden(), hidden == null ? 0 : hidden, tagRows, millis);
        log.info("成人标记已重算 enabled={} hiddenWorks={} tagRows={} {}ms",
                result.enabled(), result.hiddenWorks(), result.tagRows(), result.millis());
        return result;
    }

    /** 配置里的标记可能带通配符，不转义的话一个 {@code %} 就会把全库标成成人。 */
    private static String escapeLike(String value) {
        return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_");
    }
}
