package com.otaku.schedule.dto;

import java.time.OffsetDateTime;
import java.util.List;

/**
 * 档期导入请求体（内部接口 {@code POST /internal/import/schedules}）。
 *
 * <p>形状与作品的 {@code ImportBatchRequest} 保持一致：同样的 batch_id 幂等键、
 * 同样的 source / fetched_at、同样的逐条结果语义。这样同步侧一套 importer
 * 客户端就能发两种批次，运维看 import_batch 表也是同一套口径。
 *
 * <p>字段命名与站点 {@code GET /api/schedule} 对齐（ snake_case ），
 * 两处差异：{@code work_tags} 站点给斜杠字符串，这里收**数组**
 * （转换在同步侧做，后端不猜格式）；{@code content_id} 原样透传，
 * 关联本地作品由后端按 {@code (source, source_id)} 尽力匹配。
 */
public record ScheduleImportRequest(
        String batchId,
        String source,
        OffsetDateTime fetchedAt,
        List<ScheduleImportItem> items
) {

    public record ScheduleImportItem(
            String sourceId,
            String seasonCode,
            String titleMain,
            String titleCn,
            String titleJp,
            Integer weekday,
            String broadcastTime,
            String broadcastNote,
            String workType,
            List<String> workTags,
            String imageUrl,
            List<Platform> platforms,
            String sourceUrl,
            String contentId,
            OffsetDateTime sourceUpdatedAt
    ) {
    }

    /** 播放平台。站点给 [{name,url}]，这里原样收，不推断、不补全。 */
    public record Platform(String name, String url) {
    }
}
