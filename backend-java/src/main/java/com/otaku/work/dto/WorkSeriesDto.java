package com.otaku.work.dto;

import java.util.List;

/**
 * 详情页「系列作品」区块（#411）。
 *
 * <p>为什么不直接返回 {@code List<WorkSummaryDto>}：客户端要把系列名画成区块标题，
 * 而名字只存在于 `series` 表、不在任何一件作品上；让客户端拿第一件作品的标题去猜系列名
 * 是最常见的那种「看起来能用、换个数据就错」的做法（首部作品的标题不等于系列名）。
 *
 * <p>没有系列时返回 {@code seriesKey=null} 且 {@code items=[]}，**不是 404**：
 * 作品存在、只是不属于任何系列，这是正常状态（与 `/related`、`/articles` 同口径）。
 */
public record WorkSeriesDto(
        String seriesKey,
        String seriesName,
        List<WorkSummaryDto> items
) {
}
