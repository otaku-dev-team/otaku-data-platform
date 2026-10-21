package com.otaku.importer.dto;

import java.time.OffsetDateTime;
import java.util.List;

/**
 * `GET /internal/import/batches/{batch_id}?with_runs=true` 的响应（issue #43）。
 *
 * 只在显式要求时才返回这个形状：不传 `with_runs` 仍是原来的 {@link ImportBatchResult}，
 * 现有调用方（同步作业、日常排查脚本）拿到的 JSON 一个字段都不变。
 *
 * 顶层 `counts` 是**最近一次**运行的结果（与 `import_batch` 表一致），
 * 逐次明细在 `runs` 里，按 `runSeq` 升序。
 */
public record ImportBatchDetail(
        String batchId,
        Counts counts,
        OffsetDateTime startedAt,
        OffsetDateTime finishedAt,
        List<ImportItemResult> errors,
        int runCount,
        OffsetDateTime lastRunAt,
        List<ImportBatchRunDto> runs
) {
    public static ImportBatchDetail of(ImportBatchResult batch, int runCount,
                                       OffsetDateTime lastRunAt, List<ImportBatchRunDto> runs) {
        return new ImportBatchDetail(batch.batchId(), batch.counts(), batch.startedAt(),
                batch.finishedAt(), batch.errors(), runCount, lastRunAt, runs);
    }
}
