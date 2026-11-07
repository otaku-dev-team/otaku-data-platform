package com.otaku.series;

import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;

/**
 * 系列清单（#411）：只有 `series` 这一张表，作品侧的 {@code work.series_key} 归
 * {@link com.otaku.work.WorkRepository} 管——一张表一个仓储，别在这里顺手写 work。
 *
 * <p>为什么用 upsert 而不是「先查再插」：导入是按批并发提交的，先查后插之间仍有窗口；
 * {@code series_key} 是主键，交给 MySQL 判重最省事。名字用 {@code COALESCE} 保留旧值——
 * 数据集偶尔只给 key 不给名，那种情况下把已有名字覆盖成 NULL 是纯损失。
 */
@Repository
public class SeriesRepository {

    private final NamedParameterJdbcTemplate jdbc;

    public SeriesRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /**
     * 写入/更新一个系列；{@code name} 为空时保留库里已有的名字。
     *
     * <p>{@code updated_at} 只在名字真的变了才推进——与 work 的「内容不变就不算更新」同一口径，
     * 否则每导入一次全量，所有系列都变成「刚改过」。
     */
    public void upsert(String seriesKey, String name, LocalDateTime now) {
        jdbc.update("""
                        INSERT INTO series (series_key, name, created_at, updated_at)
                        VALUES (:seriesKey, :name, :now, :now) AS incoming
                        ON DUPLICATE KEY UPDATE
                            updated_at = IF(incoming.name <=> series.name, series.updated_at, :now),
                            name = COALESCE(incoming.name, series.name)
                        """,
                new MapSqlParameterSource()
                        .addValue("seriesKey", seriesKey)
                        .addValue("name", name)
                        .addValue("now", now));
    }

    public Optional<String> findName(String seriesKey) {
        List<String> names = jdbc.query(
                "SELECT name FROM series WHERE series_key = :seriesKey",
                new MapSqlParameterSource("seriesKey", seriesKey),
                (rs, rowNum) -> rs.getString("name"));
        return names.stream().filter(java.util.Objects::nonNull).findFirst();
    }
}
