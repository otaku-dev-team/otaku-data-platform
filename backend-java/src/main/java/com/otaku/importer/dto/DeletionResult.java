package com.otaku.importer.dto;

import java.time.OffsetDateTime;

/**
 * 软删结果（契约同名 schema）。
 *
 * <p>三个计数刻意分开，因为它们对应三种完全不同的运维判断：
 * <ul>
 *   <li>{@code accepted}：这次真的删掉的（含首次下架）；</li>
 *   <li>{@code already_deleted}：之前就删过——**重发是常态**，不能算错；</li>
 *   <li>{@code unknown}：库里没有这个 {@code (source, source_id)}（从没导过、或早被清理），
 *       单看它没意义，但和数据集对账时能立刻看出「键是不是对错了」。</li>
 * </ul>
 * 三者都不导致整批失败：一批 500 条里有一条对不上就全批回滚，只会让同步侧永远卡在那里。
 */
public record DeletionResult(
        String batchId,
        int accepted,
        int alreadyDeleted,
        int unknown,
        OffsetDateTime deletedAt
) {
}
