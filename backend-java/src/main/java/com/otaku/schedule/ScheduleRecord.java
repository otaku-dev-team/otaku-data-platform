package com.otaku.schedule;

import java.time.LocalDateTime;

/**
 * schedule 表的一行：一条新番档期。
 *
 * <p>与 {@code WorkRecord} 的关键差异：档期**不一定**对应本地作品。
 * {@code contentId} 是站点侧的作品 ID，导入时若能在 work 表里按
 * {@code (source='otaku_site', source_id=contentId)} 命中就回填 {@code workId}；
 * 未命中保持 {@code null}——客户端据此决定这条能不能跳本地详情，
 * 跳不了就只展示，不给死链。
 *
 * <p>JSON 列（{@code workTags} / {@code platforms}）与 work.tags 一致存**原文**：
 * MySQL 会把 JSON 重新格式化后读出（`["a","b"]` 变 `["a", "b"]`），
 * 若"是否变化"用字符串比较，每次重跑都会判成 changed → 变成 updated，
 * 重跑应全部 unchanged 的验收就挂了。所以读库时统一过 {@code TagsJson.canonical}
 * 归一，写入时用 ObjectMapper 序列化，两边可比。
 */
public record ScheduleRecord(
        Long id,
        String scheduleId,
        String source,
        String sourceId,
        String seasonCode,
        String titleMain,
        String titleCn,
        String titleJp,
        Integer weekday,
        String broadcastTime,
        String broadcastNote,
        String workType,
        String workTagsJson,
        String imageUrl,
        String platformsJson,
        String sourceUrl,
        String contentId,
        String workId,
        LocalDateTime sourceUpdatedAt,
        LocalDateTime createdAt,
        LocalDateTime updatedAt
) {
}
