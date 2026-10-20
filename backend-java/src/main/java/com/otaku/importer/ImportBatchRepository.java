package com.otaku.importer;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.otaku.importer.dto.Counts;
import com.otaku.importer.dto.ImportBatchResult;
import com.otaku.importer.dto.ImportItemResult;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Optional;

/**
 * 批次记录。
 *
 * 这里刻意**不做"同 batch_id 直接返回上次结果"的短路**：
 * Python 的 batch_id 只哈希 source_id 集合（pipeline.py:30-45），不含字段内容，
 * 同一天内改了评分再重跑会得到同一个 batch_id。若短路，验收 D3（改评分应更新）
 * 会永远不生效且没有任何报错。所以 batch_id 只当追踪标签，每次真实 upsert，
 * 幂等性由 work 表的 uk_source 唯一约束保证。
 * request_hash 用来区分"同 ID 不同内容"，差异会打 warn 日志便于排查。
 */
@Repository
public class ImportBatchRepository {

    private static final Logger log = LoggerFactory.getLogger(ImportBatchRepository.class);

    private static final TypeReference<List<ImportItemResult>> ERROR_LIST = new TypeReference<>() {
    };

    private final NamedParameterJdbcTemplate jdbc;
    private final ObjectMapper objectMapper;

    public ImportBatchRepository(NamedParameterJdbcTemplate jdbc, ObjectMapper objectMapper) {
        this.jdbc = jdbc;
        this.objectMapper = objectMapper;
    }

    public Optional<String> findRequestHash(String batchId) {
        List<String> rows = jdbc.query(
                "SELECT request_hash FROM import_batch WHERE batch_id = :batchId",
                new MapSqlParameterSource("batchId", batchId),
                (rs, rowNum) -> rs.getString("request_hash"));
        return rows.stream().findFirst();
    }

    public void save(ImportBatchResult result, String source, String requestHash) {
        MapSqlParameterSource params = new MapSqlParameterSource()
                .addValue("batchId", result.batchId())
                .addValue("source", source)
                .addValue("requestHash", requestHash)
                .addValue("inserted", result.counts().inserted())
                .addValue("updated", result.counts().updated())
                .addValue("unchanged", result.counts().unchanged())
                .addValue("rejected", result.counts().rejected())
                .addValue("errors", writeErrors(result.errors()))
                .addValue("startedAt", toLocal(result.startedAt()))
                .addValue("finishedAt", toLocal(result.finishedAt()));

        boolean exists = findRequestHash(result.batchId()).isPresent();
        if (exists) {
            jdbc.update("""
                    UPDATE import_batch
                       SET request_hash = :requestHash,
                           inserted = :inserted,
                           updated = :updated,
                           unchanged = :unchanged,
                           rejected = :rejected,
                           errors = :errors,
                           started_at = :startedAt,
                           finished_at = :finishedAt
                     WHERE batch_id = :batchId
                    """, params);
        } else {
            jdbc.update("""
                    INSERT INTO import_batch (batch_id, source, request_hash,
                                              inserted, updated, unchanged, rejected,
                                              errors, started_at, finished_at)
                    VALUES (:batchId, :source, :requestHash,
                            :inserted, :updated, :unchanged, :rejected,
                            :errors, :startedAt, :finishedAt)
                    """, params);
        }
    }

    public Optional<ImportBatchResult> find(String batchId) {
        List<ImportBatchResult> rows = jdbc.query("""
                        SELECT batch_id, inserted, updated, unchanged, rejected,
                               errors, started_at, finished_at
                          FROM import_batch
                         WHERE batch_id = :batchId
                        """,
                new MapSqlParameterSource("batchId", batchId),
                (rs, rowNum) -> new ImportBatchResult(
                        rs.getString("batch_id"),
                        new Counts(rs.getInt("inserted"), rs.getInt("updated"),
                                rs.getInt("unchanged"), rs.getInt("rejected")),
                        toOffset(rs.getObject("started_at", LocalDateTime.class)),
                        toOffset(rs.getObject("finished_at", LocalDateTime.class)),
                        readErrors(rs.getString("errors"))));
        return rows.stream().findFirst();
    }

    private String writeErrors(List<ImportItemResult> errors) {
        if (errors == null || errors.isEmpty()) {
            return null;
        }
        try {
            return objectMapper.writeValueAsString(errors);
        } catch (Exception ex) {
            log.warn("批次错误明细序列化失败，按空处理：{}", ex.getMessage());
            return null;
        }
    }

    private List<ImportItemResult> readErrors(String json) {
        if (json == null || json.isBlank()) {
            return List.of();
        }
        try {
            return objectMapper.readValue(json, ERROR_LIST);
        } catch (Exception ex) {
            log.warn("批次错误明细反序列化失败，按空处理：{}", ex.getMessage());
            return List.of();
        }
    }

    private static LocalDateTime toLocal(OffsetDateTime value) {
        return value == null ? null : value.withOffsetSameInstant(ZoneOffset.UTC).toLocalDateTime();
    }

    private static OffsetDateTime toOffset(LocalDateTime value) {
        return value == null ? null : value.atOffset(ZoneOffset.UTC);
    }
}
