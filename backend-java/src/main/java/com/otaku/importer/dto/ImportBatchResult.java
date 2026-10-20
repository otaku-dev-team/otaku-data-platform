package com.otaku.importer.dto;

import java.time.OffsetDateTime;
import java.util.List;

/**
 * 接口②响应体，也是 GET /internal/import/batches/{batch_id} 的返回体。
 * 不含 data 包装，字段见契约 5.3。
 */
public record ImportBatchResult(
        String batchId,
        Counts counts,
        OffsetDateTime startedAt,
        OffsetDateTime finishedAt,
        List<ImportItemResult> errors
) {
}
