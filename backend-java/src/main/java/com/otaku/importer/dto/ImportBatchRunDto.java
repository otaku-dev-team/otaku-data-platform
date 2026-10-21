package com.otaku.importer.dto;

import java.time.OffsetDateTime;
import java.util.List;

/**
 * 一次导入运行的明细（issue #43）。
 *
 * 为什么单独记：`batch_id` 由 source_id 集合哈希得出、不含运行序号，
 * 同一天重跑会覆盖 `import_batch` 的计数。要回答"这批推了几轮、每轮各是什么结果"，
 * 只能把每次运行单独存一行。
 *
 * `runSeq` 从 1 开始，按上报顺序递增；同一 `batch_id + runSeq` 唯一。
 */
public record ImportBatchRunDto(
        int runSeq,
        Counts counts,
        OffsetDateTime startedAt,
        OffsetDateTime finishedAt,
        List<ImportItemResult> errors
) {
}
