package com.otaku.console;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.console.dto.ConsoleDtos;
import com.otaku.importer.dto.Counts;
import com.otaku.importer.dto.ImportItemResult;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;

import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;

/**
 * 同步状态：最近一次跑得怎么样、失败条目是哪些。
 *
 * <p>数据源是 {@code import_batch_run}（逐次运行明细，见 V4），不是 {@code import_batch}。
 * 后者按 batch_id 覆盖，同一批重跑只看得到最后一轮——而站主问的恰恰是
 * "今天到底同步成功没有、失败了几条"，被覆盖过一次就说不清了。
 *
 * <p>**本类只读，不触发同步。** 提案 §9 把"手动触发同步"列为二期：
 * 后台一旦能触发同步，就等于给了站主一个能打满来源站的按钮，而限速责任在我们。
 * 失败补齐的入口是"看得见失败条目 + 平台侧一条命令"，边界写在这里，也写在文档里。
 */
@Service
public class ConsoleSyncService {

    private static final Logger log = LoggerFactory.getLogger(ConsoleSyncService.class);

    /** 最近运行记录展示条数。够回答"今天/昨天跑得怎么样"，不至于让页面变成长日志。 */
    private static final int RECENT_RUN_LIMIT = 20;
    /** 从最近几次运行里捞失败条目，太少看不到规律，太多页面放不下。 */
    private static final int FAILED_SCAN_RUNS = 5;
    private static final int FAILED_ITEM_LIMIT = 50;
    private static final int TREND_DAYS = 7;

    static final String RETRY_HINT =
            "失败条目已按 source_id 列出。补齐由平台运维在来源侧执行 `python -m sync --retry-failed`"
                    + "（默认读取最新一份运行报告，只补跑失败的页），后台不提供直接触发同步的按钮"
                    + "——触发同步会打满来源站，限速责任在平台侧。";

    private static final TypeReference<List<ImportItemResult>> ERROR_LIST = new TypeReference<>() {
    };

    private final NamedParameterJdbcTemplate jdbc;
    private final ObjectMapper objectMapper;

    public ConsoleSyncService(NamedParameterJdbcTemplate jdbc, ObjectMapper objectMapper) {
        this.jdbc = jdbc;
        this.objectMapper = objectMapper;
    }

    public ConsoleDtos.SyncStatus status(ConsoleScope scope) {
        List<ConsoleDtos.SyncRun> runs = recentRuns(scope);
        return new ConsoleDtos.SyncStatus(
                new ConsoleDtos.SiteView(scope.siteKey(), scope.siteName()),
                scope.sources(),
                summary(scope, runs),
                runs,
                failedItems(scope),
                RETRY_HINT);
    }

    /** 概览页用的摘要。{@code runs} 已按时间倒序，第一条即最近一次。 */
    public ConsoleDtos.SyncSummary summary(ConsoleScope scope) {
        return summary(scope, recentRuns(scope));
    }

    private ConsoleDtos.SyncSummary summary(ConsoleScope scope, List<ConsoleDtos.SyncRun> runs) {
        if (!scope.hasSources()) {
            return new ConsoleDtos.SyncSummary("never", null, null, 0, 0, 0);
        }
        ConsoleDtos.SyncRun latest = runs.isEmpty() ? null : runs.get(0);

        LocalDateTime since = LocalDateTime.now(ZoneOffset.UTC).minusDays(TREND_DAYS);
        List<long[]> trend = jdbc.query("""
                        SELECT COUNT(*)                                   AS runs,
                               COALESCE(SUM(r.rejected), 0)               AS rejected,
                               COALESCE(SUM(r.finished_at IS NULL), 0)    AS unfinished
                          FROM import_batch_run r
                          JOIN import_batch b ON b.batch_id = r.batch_id
                         WHERE b.source IN (:sources)
                           AND r.started_at >= :since
                        """,
                new MapSqlParameterSource().addValue("sources", scope.sources()).addValue("since", since),
                (rs, rowNum) -> new long[]{rs.getLong("runs"), rs.getLong("rejected"), rs.getLong("unfinished")});

        long runs7d = 0;
        long rejected7d = 0;
        long unfinished7d = 0;
        if (!trend.isEmpty()) {
            long[] row = trend.get(0);
            runs7d = row[0];
            rejected7d = row[1];
            unfinished7d = row[2];
        }

        return new ConsoleDtos.SyncSummary(
                latest == null ? "never" : latest.status(),
                latest == null ? null : latest.startedAt(),
                latest == null ? null : latest.batchId(),
                runs7d,
                unfinished7d,
                rejected7d);
    }

    private List<ConsoleDtos.SyncRun> recentRuns(ConsoleScope scope) {
        if (!scope.hasSources()) {
            return List.of();
        }
        return jdbc.query("""
                        SELECT r.batch_id, r.run_seq, b.source,
                               r.inserted, r.updated, r.unchanged, r.rejected,
                               r.started_at, r.finished_at
                          FROM import_batch_run r
                          JOIN import_batch b ON b.batch_id = r.batch_id
                         WHERE b.source IN (:sources)
                         ORDER BY r.started_at DESC, r.id DESC
                         LIMIT :limit
                        """,
                new MapSqlParameterSource()
                        .addValue("sources", scope.sources())
                        .addValue("limit", RECENT_RUN_LIMIT),
                (rs, rowNum) -> {
                    OffsetDateTime startedAt = toOffset(rs.getObject("started_at", LocalDateTime.class));
                    OffsetDateTime finishedAt = toOffset(rs.getObject("finished_at", LocalDateTime.class));
                    int rejected = rs.getInt("rejected");
                    return new ConsoleDtos.SyncRun(
                            rs.getString("batch_id"),
                            rs.getInt("run_seq"),
                            rs.getString("source"),
                            new Counts(rs.getInt("inserted"), rs.getInt("updated"),
                                    rs.getInt("unchanged"), rejected),
                            startedAt,
                            finishedAt,
                            runStatus(finishedAt, rejected));
                });
    }

    /**
     * 一次运行的三态判定。
     *
     * <p>{@code finished_at} 为空 = 这条运行没有收尾（进程被杀 / 提交后没等到结果），
     * 比"有拒收"更严重，所以先判它。旧实现只看 rejected，会把中断的运行显示成"成功"。
     */
    static String runStatus(OffsetDateTime finishedAt, int rejected) {
        if (finishedAt == null) {
            return "failed";
        }
        return rejected > 0 ? "partial" : "ok";
    }

    private List<ConsoleDtos.FailedItem> failedItems(ConsoleScope scope) {
        if (!scope.hasSources()) {
            return List.of();
        }
        List<FailedRow> rows = jdbc.query("""
                        SELECT r.batch_id, r.errors, r.started_at
                          FROM import_batch_run r
                          JOIN import_batch b ON b.batch_id = r.batch_id
                         WHERE b.source IN (:sources)
                           AND r.rejected > 0
                         ORDER BY r.started_at DESC, r.id DESC
                         LIMIT :limit
                        """,
                new MapSqlParameterSource()
                        .addValue("sources", scope.sources())
                        .addValue("limit", FAILED_SCAN_RUNS),
                (rs, rowNum) -> new FailedRow(rs.getString("batch_id"), rs.getString("errors"),
                        toOffset(rs.getObject("started_at", LocalDateTime.class))));

        List<ConsoleDtos.FailedItem> items = new ArrayList<>();
        for (FailedRow row : rows) {
            for (ImportItemResult error : parse(row.errors())) {
                if (items.size() >= FAILED_ITEM_LIMIT) {
                    return items;
                }
                items.add(new ConsoleDtos.FailedItem(row.batchId(), error.sourceId(), error.code(),
                        error.message(), row.startedAt()));
            }
        }
        return items;
    }

    private List<ImportItemResult> parse(String json) {
        if (json == null || json.isBlank()) {
            return List.of();
        }
        try {
            return objectMapper.readValue(json, ERROR_LIST);
        } catch (Exception ex) {
            // 明细解析失败不该让整个后台 500：同步状态本身还是能看的
            log.warn("同步失败明细解析失败，按空处理：{}", ex.getMessage());
            return List.of();
        }
    }

    private static OffsetDateTime toOffset(LocalDateTime value) {
        return value == null ? null : value.atOffset(ZoneOffset.UTC);
    }

    private record FailedRow(String batchId, String errors, OffsetDateTime startedAt) {
    }
}
