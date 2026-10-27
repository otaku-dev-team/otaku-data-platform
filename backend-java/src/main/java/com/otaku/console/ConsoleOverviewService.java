package com.otaku.console;

import com.otaku.console.dto.ConsoleDtos;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.List;

/**
 * 数据概览：本站作品数、字段覆盖率、同步摘要。
 *
 * <p>覆盖率口径**照抄** {@code scripts/data-coverage.sql}，不另立一套：
 * 空串与 NULL 都算"没有"、{@code rating_value} 的 NULL 是无评分（不是 0 分）、
 * {@code tags} 的 NULL（来源未提供）与 {@code []}（明确无标签）分开统计。
 * 后台如果按另一套口径算，站主就会拿着两个不一样的百分比来问"到底哪个对"。
 *
 * <p>所有查询都吃 {@link ConsoleScope#sources()}：站点没配来源时结果是 0，
 * **不会**退化成"不加 WHERE 看全库"——那种"空范围等于全部"的默认值，
 * 正是多站点后台最典型的越权入口。
 */
@Service
public class ConsoleOverviewService {

    private final NamedParameterJdbcTemplate jdbc;
    private final ConsoleScopeResolver scopeResolver;
    private final ConsoleSyncService syncService;

    public ConsoleOverviewService(NamedParameterJdbcTemplate jdbc,
                                  ConsoleScopeResolver scopeResolver,
                                  ConsoleSyncService syncService) {
        this.jdbc = jdbc;
        this.scopeResolver = scopeResolver;
        this.syncService = syncService;
    }

    public ConsoleDtos.Overview overview(ConsolePrincipal principal) {
        ConsoleScope scope = scopeResolver.resolve(principal);
        return new ConsoleDtos.Overview(
                new ConsoleDtos.SiteView(scope.siteKey(), scope.siteName()),
                scope.sources(),
                works(scope),
                coverage(scope),
                syncService.summary(scope));
    }

    private ConsoleDtos.WorksStats works(ConsoleScope scope) {
        if (!scope.hasSources()) {
            return new ConsoleDtos.WorksStats(0, List.of());
        }
        List<ConsoleDtos.TypeCount> byType = jdbc.query("""
                        SELECT work_type, COUNT(*) AS c
                          FROM work
                         WHERE source IN (:sources)
                         GROUP BY work_type
                         ORDER BY work_type
                        """,
                new MapSqlParameterSource("sources", scope.sources()),
                (rs, rowNum) -> new ConsoleDtos.TypeCount(rs.getString("work_type"), rs.getLong("c")));
        long total = byType.stream().mapToLong(ConsoleDtos.TypeCount::count).sum();
        return new ConsoleDtos.WorksStats(total, byType);
    }

    private ConsoleDtos.Coverage coverage(ConsoleScope scope) {
        if (!scope.hasSources()) {
            return new ConsoleDtos.Coverage(0, List.of());
        }
        List<long[]> rows = jdbc.query("""
                        SELECT COUNT(*) AS total,
                               COALESCE(SUM(title IS NOT NULL AND title <> ''), 0)                  AS c_title,
                               COALESCE(SUM(summary IS NOT NULL AND summary <> ''), 0)              AS c_summary,
                               COALESCE(SUM(release_year IS NOT NULL), 0)                           AS c_year,
                               COALESCE(SUM(cover_source_url IS NOT NULL AND cover_source_url <> ''), 0) AS c_cover_url,
                               COALESCE(SUM(cover_cached_at IS NOT NULL), 0)                        AS c_cover_cached,
                               COALESCE(SUM(rating_value IS NOT NULL), 0)                           AS c_rating,
                               COALESCE(SUM(tags IS NOT NULL), 0)                                   AS c_tags_provided,
                               COALESCE(SUM(tags IS NOT NULL AND JSON_LENGTH(tags) > 0), 0)          AS c_tags_nonempty,
                               COALESCE(SUM(source_url IS NOT NULL AND source_url <> ''), 0)         AS c_source_url
                          FROM work
                         WHERE source IN (:sources)
                        """,
                new MapSqlParameterSource("sources", scope.sources()),
                (rs, rowNum) -> new long[]{
                        rs.getLong("total"),
                        rs.getLong("c_title"),
                        rs.getLong("c_summary"),
                        rs.getLong("c_year"),
                        rs.getLong("c_cover_url"),
                        rs.getLong("c_cover_cached"),
                        rs.getLong("c_rating"),
                        rs.getLong("c_tags_provided"),
                        rs.getLong("c_tags_nonempty"),
                        rs.getLong("c_source_url")});

        long[] row = rows.isEmpty()
                ? new long[]{0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
                : rows.get(0);
        long total = row[0];

        List<ConsoleDtos.FieldCoverage> fields = new ArrayList<>();
        fields.add(field("title", row[1], total));
        fields.add(field("summary", row[2], total));
        fields.add(field("release_year", row[3], total));
        fields.add(field("cover_source_url", row[4], total));
        fields.add(field("cover_cached_at", row[5], total));
        fields.add(field("rating_value", row[6], total));
        fields.add(field("tags_provided", row[7], total));
        fields.add(field("tags_nonempty", row[8], total));
        fields.add(field("source_url", row[9], total));
        return new ConsoleDtos.Coverage(total, fields);
    }

    private static ConsoleDtos.FieldCoverage field(String name, long present, long total) {
        double percent = total == 0 ? 0.0 : Math.round(present * 1000.0 / total) / 10.0;
        return new ConsoleDtos.FieldCoverage(name, present, percent);
    }
}
