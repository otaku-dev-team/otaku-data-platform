package com.otaku.work.dto;

import java.util.List;

/**
 * 列表项：**8 个字段，不含 summary**（契约 2.1 / 6.1）。
 * 简介最长 7225 字，带进列表会把响应撑爆——需要简介请按 work_id 拉详情。
 *
 * <p>`source` 是 2026-10-24 补上的第 8 个字段（原方案见 `docs/d3-cross-source-identity-proposal.md`）：
 * 列表 SQL 本来就 select 了 `source`，只是没往 DTO 里透出，跨源同名作品在列表层无法区分。
 * 按「齐平原则」它是**透明度底线**——目录里只要出现非本站的记录，用户就得能分辨，
 * 它不是归并（E1/W2）的前奏，也不改变"来源即事实"的快照语义。
 */
public record WorkSummaryDto(
        String workId,
        String workType,
        String title,
        Integer releaseYear,
        String coverUrl,
        List<String> tags,
        SourceRatingDto mainRating,
        String source
) {
}
