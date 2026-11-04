package com.otaku.view;

import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

import java.time.LocalDateTime;

/**
 * 浏览行为表（{@code user_work_view}）的读写。
 *
 * <p>表是**有界行**：一个用户对一部作品只有一行（主键 {@code user_id, work_id}），
 * 再次浏览只推进 {@code last_viewed_at} 并累加 {@code view_count}，不会新增行。
 */
@Repository
public class ViewRepository {

    private final NamedParameterJdbcTemplate jdbc;

    public ViewRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /**
     * 记一次浏览。一次 upsert 而不是「先查再插/改」：
     * 打点是并发最密集的写入口，两步之间被人插一脚就会主键冲突。
     */
    public void record(long userId, String workId, LocalDateTime now) {
        jdbc.update("""
                        INSERT INTO user_work_view (user_id, work_id, first_viewed_at, last_viewed_at, view_count)
                        VALUES (:userId, :workId, :now, :now, 1)
                        ON DUPLICATE KEY UPDATE last_viewed_at = VALUES(last_viewed_at),
                                                view_count = view_count + 1
                        """,
                new MapSqlParameterSource()
                        .addValue("userId", userId)
                        .addValue("workId", workId)
                        .addValue("now", now));
    }

    /** 删掉最后浏览时间早于 {@code cutoff} 的行，返回删除条数。 */
    public int purgeBefore(LocalDateTime cutoff) {
        return jdbc.update("DELETE FROM user_work_view WHERE last_viewed_at < :cutoff",
                new MapSqlParameterSource("cutoff", cutoff));
    }

    /** 某用户最近的浏览（测试与后续「浏览历史」复用）。 */
    public int countFor(long userId) {
        Integer count = jdbc.queryForObject(
                "SELECT COUNT(*) FROM user_work_view WHERE user_id = :userId",
                new MapSqlParameterSource("userId", userId), Integer.class);
        return count == null ? 0 : count;
    }
}
